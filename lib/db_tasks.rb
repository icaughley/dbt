BASE_APP_DIR = RAILS_ROOT unless defined? BASE_APP_DIR
APP_VERSION = nil unless defined? APP_VERSION
DB_ENV = ENV['DB_ENV'] || RAILS_ENV unless defined? DB_ENV

# Note the following terminology is used throughout the plugin
# * database_key: a symbolic name of database. i.e. "central", "master", "core",
#   "ifis", "msdb" etc
# * env: a development environment. i.e. "test", "development", "production"
# * schema: name of the database directory in which sets of related database
#   files are stored. i.e. "audit", "auth", "interpretation", ...
# * config_key: the name of entry in YAML file to look up configuration. Typically
#   constructed by database_key and env separated by an underscore. i.e.
#   "central_development", "master_test" etc.

# It should also be noted that the in some cases there is a database_key and
# schema with the same name. This was due to legacy reasons and should be avoided
# in the future as it is confusing

require File.expand_path(File.dirname(__FILE__) + '/init_ar.rb')
require 'active_record/fixtures'
require File.expand_path(File.dirname(__FILE__) + '/foreign_key_support.rb')

# The following two class monkey patches make the migrations transactional
class ActiveRecord::Migration
  def self.migrate_with_transactional_migrations(direction)
    ActiveRecord::Base.transaction { migrate_without_transactional_migrations(direction) }
  end
end

class ActiveRecord::Migration
  class << self
    alias_method_chain :migrate, :transactional_migrations
  end
end

class DbTasks
  @@seen_schemas = {}
  @@filters = []
  @@default_schema = "default"
  @@table_order_resolver = nil

  def self.init(schema, env)
    setup_connection(config_key(schema,env))
  end

  def self.add_filter( &block )
    @@filters << block
  end

  def self.define_table_order_resolver( &block )
    @@table_order_resolver = block
  end

  def self.default_schema=(s)
    @@default_schema = s.to_s
  end

  def self.default_schema
    @@default_schema
  end

  def self.add_database( database_key, schemas, options = {} )
    database_key = database_key.to_s
    namespace :db do
      schemas.each do |schema|
        next if @@seen_schemas.include? schema
        @@seen_schemas[ schema ] = datasets_for_schema( schema )
      end

      namespace database_key do
        desc "Create initial #{database_key} database."
        task :create => ['db:load_config', "db:#{database_key}:banner", "db:#{database_key}:pre_build", "db:#{database_key}:build", "db:#{database_key}:post_build"]

        task "db:#{database_key}:banner" do
          check_db_env
          puts "**** Creating database: #{database_key} (Environment: #{DB_ENV}) ****"
        end

        task :pre_build => ['db:load_config','db:pre_build']

        schemas.each do |schema|
          task :build => "post_schema_#{schema}"

          task "post_schema_#{schema}" => "db:#{database_key}:build_schema_#{schema}"

          task "build_schema_#{schema}" => "db:#{database_key}:pre_schema_#{schema}"

          task "pre_schema_#{schema}"
        end

        schemas.each_with_index do |schema, idx|
          task "build_schema_#{schema}" do
            DbTasks.create( schema.to_s, DB_ENV, database_key, idx == 0 )
          end
        end

        task :post_build do
        end

        desc "Import contents of #{database_key} database."
        task :import => ['db:load_config'] do
          check_db_env
          import_schemas = options[:import] || schemas
          import_schemas.each do |schema|
            DbTasks.import( schema.to_s, DB_ENV, database_key )
          end
        end

        desc "Drop #{database_key} database."
        task :drop => ['db:load_config'] do
          check_db_env
          puts "**** Dropping database: #{database_key} ****"
          DbTasks.drop( database_key, DB_ENV )
        end

        datasets = datasets_for_schemas( schemas )
        if datasets.any?
          namespace :datasets do
            datasets.each do |dataset_names, schemas_in_dataset|
              dataset_names.each do |dataset_name|
                desc "Loads #{dataset_name} #{schemas_in_dataset.to_sentence} data"
                task dataset_name => :environment do
                  check_db_env
                  schemas_in_dataset.each do |schema_name|
                    DbTasks.load_dataset( DB_ENV, schema_name.to_s, dataset_name )
                  end
                end
              end
            end
          end
        end
      end

      desc "Create all databases."
      task :create => ["db:#{database_key}:create"] do
      end

      desc "Drop all databases."
      task :drop => ["db:#{database_key}:drop"] do
      end
    end
  end

  def self.create(schema, env, database_key = nil, recreate = true)
    database_key = schema unless database_key
    key = config_key(database_key,env)
    physical_name = get_config(key)['database']
    if recreate
      setup_connection("msdb", key)
      recreate_db(database_key, env, true)
    else
      setup_connection(key)
    end
    puts "Database Load [#{physical_name}]: schema=#{schema}, db=#{database_key}, env=#{env}, key=#{key}\n" if ActiveRecord::Migration.verbose
    process_schema(database_key, schema, env)
  end

  def self.run_generated_sql(database_key, env, label, distributed_dir, development_dir)
    if File.exists?( distributed_dir )
      run_sql_in_dir( database_key, env, label, distributed_dir )
    else
      run_sql_in_dir( database_key, env, label, development_dir )
    end
  end

  def self.run_sql_in_dir(database_key, env, label, dir)
    check_dir(label, dir)
    Dir["#{dir}/*.sql"].sort.each do |sp|
      puts "#{label}: #{File.basename(sp)}\n"
      run_filtered_sql(database_key, env, IO.readlines(sp).join)
    end
  end

  def self.import(schema, env, database_key = nil)
    ordered_tables = table_ordering(schema)
    unless ordered_tables
      puts "Skipping import of schema #{schema_key}, as unable to determine table_ordering"
      return
    end

    database_key = schema unless database_key

    # check the database configurations are set
    target_config = config_key(database_key,env)
    source_config = config_key(database_key,"import")
    get_config(target_config)
    get_config(source_config)

    phsyical_name = get_config(target_config)['database']
    puts "Database Import [#{phsyical_name}]: schema=#{schema}, db=#{database_key}, env=#{env}, source_key=#{source_config} target_key=#{target_config}\n" if ActiveRecord::Migration.verbose
    setup_connection(target_config)

    # Iterate over schema in dependency order doing import as appropriate
    # Note: that tables with initial fixtures are skipped
    tables = ordered_tables.reject do |table|
      fixture_for_creation(schema, table)
    end
    tables.reverse.each do |table|
      puts "Deleting #{table}\n"
      q_table = to_qualified_table_name(table)
      run_import_sql(schema, env, database_key, "DELETE FROM @@TARGET@@.#{q_table}")
    end

    tables.each do |table|
      perform_import(schema, env, database_key, table)
    end

    tables.each do |table|
      puts "Reindexing #{table}\n"
      q_table = to_qualified_table_name(table)
      run_import_sql(schema, env, database_key, "DBCC DBREINDEX (N'@@TARGET@@.#{q_table}', '', 0) WITH NO_INFOMSGS")
    end

    run_import_sql(schema, env, database_key, "DBCC SHRINKDATABASE(N'@@TARGET@@', 10, NOTRUNCATE) WITH NO_INFOMSGS")
    run_import_sql(schema, env, database_key, "DBCC SHRINKDATABASE(N'@@TARGET@@', 10, TRUNCATEONLY) WITH NO_INFOMSGS")
    run_import_sql(schema, env, database_key, "EXEC @@TARGET@@.dbo.sp_updatestats")
  end

  def self.drop_schema(database_key, schema, env)
    key = config_key(database_key,env)
    setup_connection("msdb", key)
    current_database = get_config(key)['database']
    c = ActiveRecord::Base.connection
    c.transaction do
      c.execute("USE [#{current_database}]")
      ordered_tables = table_ordering(schema)
      raise "Unknown schema #{schema}" unless ordered_tables
      ordered_tables.reverse.each do |t|
        c.execute("DROP TABLE #{t.to_s}")
      end
      c.execute("DROP SCHEMA [#{schema.capitalize}]")
    end
  end

  def self.drop(database_key, env)
    key = config_key(database_key,env)
    setup_connection("msdb", key)
    db = get_config(key)['database']
    sql = <<SQL
USE [msdb]
GO
  IF EXISTS
    ( SELECT *
      FROM  sys.master_files
      WHERE state = 0 AND db_name(database_id) = '#{db}')
    DROP DATABASE [#{db}]
GO
SQL
    puts "Database Drop [#{db}]: database_key=#{database_key}, env=#{env}, key=#{key}\n" if ActiveRecord::Migration.verbose
    run_filtered_sql(database_key, env, sql)
  end

  def self.filter_database_name(sql, pattern, current_config_key, target_database_config_key, optional = true)
    return sql if optional && ActiveRecord::Base.configurations[target_database_config_key].nil?
    sql.gsub( pattern, get_db_spec(current_config_key, target_database_config_key) )
  end

  private

  def self.table_ordering(schema_key)
    if @@table_order_resolver
      return @@table_order_resolver.call(schema_key)
    else
      begin
        return "#{schema_key.split('-').collect { |e| e.capitalize }.join('')}OrderedTables".constantize
      rescue => e
        return nil
      end
    end
  end

  @@search_dirs = ["#{BASE_APP_DIR}/databases/generated", "#{BASE_APP_DIR}/databases" ]
  def self.search_dirs
    @@search_dirs
  end

  def self.config_key(schema, env)
    schema == default_schema ? env : "#{schema}_#{env}"
  end

  def self.to_qualified_table_name(table)
    elements = table.to_s.split('.')
    elements = ['dbo', elements[0]] if elements.size == 1
    elements.join('.')
  end

  def self.run_import_sql(schema, env, database_key, sql, change_to_msdb = true)
    target_config = config_key(database_key,env)
    source_config = config_key(database_key,"import")
    sql = filter_import_sql(sql, env, target_config, source_config)
    c = ActiveRecord::Base.connection
    current_database = get_config(target_config)["database"]
    if change_to_msdb
      c.execute "USE [msdb]"
      run_filtered_sql_for_env("msdb", "import", sql)
      c.execute "USE [#{current_database}]"
    else
      run_filtered_sql_for_env(target_config, env, sql)
    end
  end

  def self.perform_standard_import(schema, env, database_key, table)
    q_table = to_qualified_table_name(table)
    sql = "INSERT INTO @@TARGET@@.#{q_table}("
    columns = ActiveRecord::Base.connection.columns(q_table).collect {|c| "[#{c.name}]"}
    sql += columns.join(', ')
    sql += ")\n  SELECT "
    sql += columns.collect {|c| c == '[BatchID]' ? "0" : c}.join(', ')
    sql += " FROM @@SOURCE@@.#{q_table}\n"

    run_import_sql(schema, env, database_key, sql)
  end

  def self.perform_import(schema, env, database_key, table)
    has_identity = has_identity_column(table)

    q_table = to_qualified_table_name(table)

    run_import_sql(schema, env, database_key, "SET IDENTITY_INSERT @@TARGET@@.#{q_table} ON") if has_identity
    run_import_sql(schema, env, database_key, "EXEC sp_executesql \"DISABLE TRIGGER ALL ON @@TARGET@@.#{q_table}\"", false)

    fixture_file = fixture_for_import(schema, table)
    sql_file = sql_for_import(schema, table)
    is_sql = !fixture_file && sql_file

    puts "Importing #{table} (By #{fixture_file ? 'F' : is_sql ? 'S' : "D"})\n"
    if fixture_file
      Fixtures.create_fixtures(File.dirname(fixture_file), table)
    elsif is_sql
      run_import_sql(schema, env, database_key, IO.readlines(sql_file).join)
    else
      perform_standard_import(schema, env, database_key, table)
    end

    run_import_sql(schema, env, database_key, "EXEC sp_executesql \"ENABLE TRIGGER ALL ON @@TARGET@@.#{q_table}\"",false)
    run_import_sql(schema, env, database_key, "SET IDENTITY_INSERT @@TARGET@@.#{q_table} OFF") if has_identity
  end

  def self.filter_import_sql(sql, env, target_config, source_config)
    sql = filter_database_name(sql, /@@SOURCE@@/, "msdb", source_config)
    sql = filter_database_name(sql, /@@TARGET@@/, "msdb", target_config)
    sql
  end

  def self.has_identity_column(table)
    ActiveRecord::Base.connection.columns(table).each do |c|
      return true if c.identity == true
    end
    false
  end

  def self.setup_connection(config_key, log_name = nil)
    log_file = "#{BASE_APP_DIR}/tmp/logs/db/#{log_name || config_key}.log"
    ActiveRecord::Base.colorize_logging = false
    ActiveRecord::Base.establish_connection(get_config(config_key))
    FileUtils.mkdir_p File.dirname(log_file)
    ActiveRecord::Base.logger = Logger.new(File.open(log_file, 'a'))
    ActiveRecord::Migration.verbose = ENV["VERBOSE"] ? ENV["VERBOSE"] == "true" : false
  end

  def self.drop_schema_info
    c = ActiveRecord::Base.connection
    c.transaction do
      begin
        c.execute("DROP TABLE [#{ActiveRecord::Migrator.schema_migrations_table_name}]")
      rescue => e
        # Ignore. Probably not there
      end
    end
  end

  def self.recreate_db(database_key, env, cs = true)
    drop(database_key, env)
    key = config_key(database_key,env)
    config = get_config(key)
    db_name = config['database']
    collation = cs ? 'COLLATE SQL_Latin1_General_CP1_CS_AS' : ''
    if APP_VERSION.nil?
      db_filename = db_name
    else
      db_filename = "#{db_name}_#{APP_VERSION.gsub(/\./, '_')}"
    end
    db_def = config["data_path"] ? "ON PRIMARY (NAME = [#{db_filename}], FILENAME='#{config["data_path"]}#{"\\"}#{db_filename}.mdf')" : ""
    log_def = config["log_path"] ? "LOG ON (NAME = [#{db_filename}_LOG], FILENAME='#{config["log_path"]}#{"\\"}#{db_filename}.ldf')" : ""

    sql = <<SQL
CREATE DATABASE [#{db_name}] #{db_def} #{log_def} #{collation}
GO
ALTER DATABASE [#{db_name}] SET CURSOR_DEFAULT LOCAL
ALTER DATABASE [#{db_name}] SET CURSOR_CLOSE_ON_COMMIT ON

ALTER DATABASE [#{db_name}] SET AUTO_CREATE_STATISTICS ON
ALTER DATABASE [#{db_name}] SET AUTO_UPDATE_STATISTICS ON
ALTER DATABASE [#{db_name}] SET AUTO_UPDATE_STATISTICS_ASYNC ON

ALTER DATABASE [#{db_name}] SET ANSI_NULL_DEFAULT ON
ALTER DATABASE [#{db_name}] SET ANSI_NULLS ON
ALTER DATABASE [#{db_name}] SET ANSI_PADDING ON
ALTER DATABASE [#{db_name}] SET ANSI_WARNINGS ON
ALTER DATABASE [#{db_name}] SET ARITHABORT ON
ALTER DATABASE [#{db_name}] SET CONCAT_NULL_YIELDS_NULL ON
ALTER DATABASE [#{db_name}] SET QUOTED_IDENTIFIER ON
ALTER DATABASE [#{db_name}] SET NUMERIC_ROUNDABORT ON
ALTER DATABASE [#{db_name}] SET RECURSIVE_TRIGGERS ON

ALTER DATABASE [#{db_name}] SET RECOVERY SIMPLE

GO
  USE [#{db_name}]
SQL
    puts "Database Create [#{db_name}]: schema=#{database_key}, env=#{env}, key=#{key}\n" if ActiveRecord::Migration.verbose
    run_filtered_sql(database_key, env, sql)
  end

  def self.process_schema(database_key, schema, env)
    create_schema_from_file( database_key, schema, env ) || create_schema_from_migrations( schema )

    dirs = ['types', 'views', 'functions', 'stored-procedures', 'triggers', 'misc']
    dirs << 'jobs' if env =~ /production$/
    dirs.each do |dir|
      run_sql_in_dirs(database_key, env, dir.humanize, dirs_for_schema( schema, dir ) )
    end
    load_fixtures_from_dirs(schema, dirs_for_schema(schema, 'fixtures'))
  end

  def self.create_schema_from_file( database_key, schema, env )
    dirs = dirs_for_schema(schema)
    dirs.each do |dir|
      sql_file = "#{dir}/schema.sql"
      if File.exist?(sql_file)
        puts "Loading Schema: #{sql_file}\n"
        run_filtered_sql(database_key, env, IO.readlines(sql_file).join)
        return true
      end
      if File.exist?("#{dir}/schema.rb")
        load_db_schema("#{dir}/schema.rb")
        return true
      end
    end
    false
  end

  def self.create_schema_from_migrations(schema)
    dirs_for_schema(schema, 'migrations').each do |dir|
      if File.exist?(dir)
        migrate_db(dir)
        return true
      end
    end
    false
  end

  def self.check_dir(name, dir)
    raise "#{name} in missing dir #{dir}" unless File.exists?(dir)
  end

  def self.migrate_db(migrations_dir)
    check_dir('migrate', migrations_dir)
    puts "Migrating: #{migrations_dir}\n"
    ActiveRecord::Migrator.migrate(migrations_dir, nil)
    drop_schema_info
  end

  def self.load_db_schema(schema_file)
    check_file(schema_file)
    puts "Loading Schema: #{schema_file}\n"
    load schema_file
    drop_schema_info
  end

  def self.check_file(file)
    raise "#{file} file is missing" unless File.exists?(file)
  end

  def self.load_dataset(env, schema, dataset_name)
    setup_connection( env )
    load_fixtures_from_dirs(schema, dirs_for_schema(schema, "datasets/#{dataset_name}"))
  end

  def self.load_fixtures_from_dirs(schema, dirs)
    require 'active_record/fixtures'
    dir = dirs.select{|dir| File.exists?(dir)}[0]
    return unless dir
    ordered_tables = table_ordering(schema)
    mode = nil
    if ordered_tables
      files = []
      ordered_tables.each do |t|
        files += [t] if File.exist?("#{dir}/#{t}.yml")
      end
      mode = "O"
    else
      files = Dir.glob(dir + "/*.yml").map { |f| File.basename(f, ".yml") }.split(/,/)
      mode = "A"
    end
    puts("Loading fixtures (#{mode}): #{files.join(',')}")
    Fixtures.create_fixtures(dir, files)
  end

  def self.run_sql(sql, hint)
    sql.gsub(/\r/, '').split("\nGO\n").each do |ddl|
      # Transaction required to work around a bug that sometimes leaves last
      # SQL command before shutting the connection un committed.
      ActiveRecord::Base.connection.transaction do
        ActiveRecord::Base.connection.execute(ddl, nil, hint)
      end
    end
  end

  def self.get_config(config_key)
    c = ActiveRecord::Base.configurations[config_key]
    raise "Missing config for #{config_key}" unless c
    c
  end

  def self.get_db_spec(current_config_key, target_config_key)
    current = ActiveRecord::Base.configurations[current_config_key]
    target = get_config(target_config_key)
    if current.nil? || current['host'] != target['host']
      "#{target['host']}.#{target['database']}"
    else
      target['database']
    end
  end

  def self.run_filtered_sql(database_key, env, sql)
    run_filtered_sql_for_env(config_key(database_key,env), env, sql)
  end

  def self.filter_sql(config_key, env, sql)
    sql = filter_database_name(sql, /@@SELF@@/, config_key, config_key)
    @@filters.each do |filter|
      sql = filter.call(config_key, env, sql)
    end
    sql
  end

  def self.run_filtered_sql_for_env(config_key, env, sql, hint = :update)
    sql = filter_sql(config_key, env, sql)
    run_sql(sql, hint)
  end

  def self.run_sql_in_dirs(database_key, env, label, dirs)
    dirs.each do |dir|
      run_sql_in_dir(database_key, env, label, dir) if File.exists?(dir)
    end
  end

  def self.run_sql_in_dir(database_key, env, label, dir)
    check_dir(label, dir)
    Dir["#{dir}/*.sql"].sort.each do |sp|
      puts "#{label}: #{File.basename(sp)}\n"
      run_filtered_sql(database_key, env, IO.readlines(sp).join)
    end
  end

  def self.datasets_for_schema( name )
    dataset_dirs = dirs_for_schema(name, 'datasets/')
    datasets = []
    dataset_dirs.each do |dataset_dir|
      next unless File.exists?( dataset_dir )
      datasets << Dir.glob( "#{dataset_dir}*" ).select { |subdir| File.directory?( subdir ) }.map { |subdir| subdir[dataset_dir.size..-1] }
    end
    datasets.empty? ? nil : datasets
  end

  def self.datasets_for_schemas( schemas )
    datasets = {}
    schemas.each do |schema|
      (@@seen_schemas[schema] || []).each do |dataset|
        datasets[dataset] ||= []
        datasets[dataset] << schema
      end
    end
    datasets
  end

  def self.dirs_for_schema(schema, subdir = nil)
    search_dirs.map{|d| "#{d}/#{schema}#{ subdir ? "/#{subdir}" : ''}"}
  end

  def self.first_file_from( files )
    files.each do |file|
      if File.exist?(file)
        return file
      end
    end
    nil
  end

  def self.fixture_for_creation(schema, table)
    first_file_from( dirs_for_schema(schema, "fixtures/#{table}.yml") )
  end

  def self.fixture_for_import(schema, table)
    first_file_from( dirs_for_schema(schema, "import/#{table}.yml") )
  end

  def self.sql_for_import(schema, table)
    first_file_from( dirs_for_schema(schema, "import/#{table}.sql") )
  end
end
