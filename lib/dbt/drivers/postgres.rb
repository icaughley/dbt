#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class Dbt
  class PostgresDbConfig < JdbcDbConfig
    def self.jdbc_driver_dependencies
      %w{postgresql:postgresql:jar:9.1-901.jdbc4}
    end

    def jdbc_driver
      'org.postgresql.Driver'
    end

    def jdbc_url(use_control_catalog)
      url = "jdbc:postgresql://#{host}:#{port}/"
      url += use_control_catalog ? control_catalog_name : catalog_name
      url
    end

    def jdbc_info
      info = java.util.Properties.new
      info.put('user', username) if username
      info.put('password', password) if password
      info.put('ssl', ssl)
      info
    end

    def control_catalog_name
      'postgres'
    end

    def host
      config_value("host", false)
    end

    def port
      config_value("port", true) || 5432
    end

    def ssl
      ssl = config_value("ssl", true)
      ssl.nil? ? false : true
    end

    def username
      config_value("username", true)
    end

    def password
      config_value("password", true)
    end
  end

  class PostgresDbDriver < JdbcDbDriver
    include Dbt::Dialect::Postgres
  end
end
