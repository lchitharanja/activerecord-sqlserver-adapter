module ActiveRecord
  module ConnectionAdapters
    module SQLServer
      module DatabaseStatements

        def select_rows(sql, name = nil, binds = [])
          sp_executesql sql, name, binds, fetch: :rows
        end

        def execute(sql, name = nil)
          if id_insert_table_name = query_requires_identity_insert?(sql)
            with_identity_insert_enabled(id_insert_table_name) { do_execute(sql, name) }
          else
            do_execute(sql, name)
          end
        end

        def exec_query(sql, name = 'SQL', binds = [], prepare: false)
          sp_executesql(sql, name, binds, prepare: prepare)
        end

        def exec_insert(sql, name, binds, pk = nil, _sequence_name = nil)
          if id_insert_table_name = exec_insert_requires_identity?(sql, pk, binds)
            with_identity_insert_enabled(id_insert_table_name) { exec_query(sql, name, binds) }
          else
            exec_query(sql, name, binds)
          end
        end

        def exec_delete(sql, name, binds)
          #sql << '; SELECT @@ROWCOUNT AS AffectedRows'
          #super.rows.first.first
          super.rows.first.try(:first) || super("SELECT @@ROWCOUNT As AffectedRows", "", []).rows.first.try(:first)
        end

        def exec_update(sql, name, binds)
          #sql << '; SELECT @@ROWCOUNT AS AffectedRows'
          #super.rows.first.first
          super.rows.first.try(:first) || super("SELECT @@ROWCOUNT As AffectedRows", "", []).rows.first.try(:first)
        end

        def supports_statement_cache?
          true
        end

        def begin_db_transaction
          do_execute 'BEGIN TRANSACTION'
        end

        def transaction_isolation_levels
          super.merge snapshot: "SNAPSHOT"
        end

        def begin_isolated_db_transaction(isolation)
          set_transaction_isolation_level transaction_isolation_levels.fetch(isolation)
          begin_db_transaction
        end

        def set_transaction_isolation_level(isolation_level)
          do_execute "SET TRANSACTION ISOLATION LEVEL #{isolation_level}"
        end

        def commit_db_transaction
          do_execute 'COMMIT TRANSACTION'
        end

        def exec_rollback_db_transaction
          do_execute 'IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION'
        end

        include Savepoints

        def create_savepoint(name = current_savepoint_name)
          do_execute "SAVE TRANSACTION #{name}"
        end

        def exec_rollback_to_savepoint(name = current_savepoint_name)
          do_execute "ROLLBACK TRANSACTION #{name}"
        end

        def release_savepoint(name = current_savepoint_name)
        end

        def case_sensitive_comparison(table, attribute, column, value)
          if value && value.acts_like?(:string)
            table[attribute].eq(Arel::Nodes::Bin.new(Arel::Nodes::BindParam.new))
          else
            super
          end
        end

        def can_perform_case_insensitive_comparison_for?(column)
          column.type == :string
        end
        private :can_perform_case_insensitive_comparison_for?

        # === SQLServer Specific ======================================== #

        def execute_procedure(proc_name, *variables)
          vars = if variables.any? && variables.first.is_a?(Hash)
                   variables.first.map { |k, v| "@#{k} = #{quote(v)}" }
                 else
                   variables.map { |v| quote(v) }
                 end.join(', ')
          sql = "EXEC #{proc_name} #{vars}".strip
          name = 'Execute Procedure'
          log(sql, name) do
            case @connection_options[:mode]
            when :dblib
              result = @connection.execute(sql)
              options = { as: :hash, cache_rows: true, timezone: ActiveRecord::Base.default_timezone || :utc }
              result.each(options) do |row|
                r = row.with_indifferent_access
                yield(r) if block_given?
              end
              result.each.map { |row| row.is_a?(Hash) ? row.with_indifferent_access : row }
            when :odbc
              results = []
              raw_connection_run(sql) do |handle|
                get_rows = lambda do
                  rows = handle_to_names_and_values handle, fetch: :all
                  rows.each_with_index { |r, i| rows[i] = r.with_indifferent_access }
                  results << rows
                end
                get_rows.call
                get_rows.call while handle_more_results?(handle)
              end
              results.many? ? results : results.first
            end
          end
        end

        def with_identity_insert_enabled(table_name)
          table_name = quote_table_name(table_name)
          set_identity_insert(table_name, true)
          yield
        ensure
          set_identity_insert(table_name, false)
        end

        def use_database(database = nil)
          return if sqlserver_azure?
          name = SQLServer::Utils.extract_identifiers(database || @connection_options[:database]).quoted
          do_execute "USE #{name}" unless name.blank?
        end

        def user_options
          return {} if sqlserver_azure?
          rows = select_rows('DBCC USEROPTIONS WITH NO_INFOMSGS', 'SCHEMA')
          rows = rows.first if rows.size == 2 && rows.last.empty?
          rows.reduce(HashWithIndifferentAccess.new) do |values, row|
            if row.instance_of? Hash
              set_option = row.values[0].gsub(/\s+/, '_')
              user_value = row.values[1]
            elsif  row.instance_of? Array
              set_option = row[0].gsub(/\s+/, '_')
              user_value = row[1]
            end
            values[set_option] = user_value
            values
          end
        end

        def user_options_dateformat
          if sqlserver_azure?
            select_value 'SELECT [dateformat] FROM [sys].[syslanguages] WHERE [langid] = @@LANGID', 'SCHEMA'
          else
            user_options['dateformat']
          end
        end

        def user_options_isolation_level
          if sqlserver_azure?
            sql = %(SELECT CASE [transaction_isolation_level]
                    WHEN 0 THEN NULL
                    WHEN 1 THEN 'READ UNCOMMITTED'
                    WHEN 2 THEN 'READ COMMITTED'
                    WHEN 3 THEN 'REPEATABLE READ'
                    WHEN 4 THEN 'SERIALIZABLE'
                    WHEN 5 THEN 'SNAPSHOT' END AS [isolation_level]
                    FROM [sys].[dm_exec_sessions]
                    WHERE [session_id] = @@SPID).squish
            select_value sql, 'SCHEMA'
          else
            user_options['isolation_level']
          end
        end

        def user_options_language
          if sqlserver_azure?
            select_value 'SELECT @@LANGUAGE AS [language]', 'SCHEMA'
          else
            user_options['language']
          end
        end

        def newid_function
          select_value 'SELECT NEWID()'
        end

        def newsequentialid_function
          select_value 'SELECT NEWSEQUENTIALID()'
        end


        protected

        def sql_for_insert(sql, pk, id_value, sequence_name, binds)
          if pk.nil?
            table_name = query_requires_identity_insert?(sql)
            pk = primary_key(table_name)
          end

          sql = if pk && self.class.use_output_inserted && !database_prefix_remote_server?
                  quoted_pk = SQLServer::Utils.extract_identifiers(pk).quoted
                  sql.insert sql.index(/ (DEFAULT )?VALUES/), " OUTPUT INSERTED.#{quoted_pk}"
                else
                  #"#{sql}; SELECT CAST(SCOPE_IDENTITY() AS bigint) AS Ident"
                  #sql.dup.sub!(" VALUES(", " OUTPUT Inserted.ID VALUES(")
                  table = sql.match('^INSERT.*?\[(.*?)\]').try(:[], 1)
                  id_col = table ? primary_key(table.to_s.strip) : nil
                  output = id_col ? "INSERTED.#{id_col}, " : ''
                  if id_col.blank?
                    sql.dup.sub!(" VALUES(", " OUTPUT Inserted.ID VALUES (")
                  else
                    sql.dup.sub!(" VALUES(", " OUTPUT CAST(COALESCE(#{output}@@IDENTITY, SCOPE_IDENTITY()) AS bigint) AS Ident VALUES (")
                  end
                end
          super
        end

        # === SQLServer Specific ======================================== #

        def set_identity_insert(table_name, enable = true)
          do_execute "SET IDENTITY_INSERT #{table_name} #{enable ? 'ON' : 'OFF'}"
        rescue Exception
          raise ActiveRecordError, "IDENTITY_INSERT could not be turned #{enable ? 'ON' : 'OFF'} for table #{table_name}"
        end

        # === SQLServer Specific (Executing) ============================ #

        def do_execute(sql, name = 'SQL')
          log(sql, name) { raw_connection_do(sql) }
        end

        def sp_executesql(sql, name, binds, options = {})
          options[:ar_result] = true if options[:fetch] != :rows
          unless without_prepared_statement?(binds)
            types, params = sp_executesql_types_and_parameters(binds)
            sql = sp_executesql_sql(sql, types, params, name)
          end
          raw_select sql, name, binds, options
        end

        def sp_executesql_types_and_parameters(binds)
          types, params = [], []
          binds.each_with_index do |attr, index|
            types << "@#{index} #{sp_executesql_sql_type(attr)}"
            params << sp_executesql_sql_param(attr)
          end
          [types, params]
        end

        def sp_executesql_sql_type(attr)
          return attr.type.sqlserver_type if attr.type.respond_to?(:sqlserver_type)
          case value = attr.value_for_database
          when Numeric
            'int'.freeze
          else
            'nvarchar(max)'.freeze
          end
        end

        def sp_executesql_sql_param(attr)
          case attr.value_for_database
          when Type::Binary::Data,
               ActiveRecord::Type::SQLServer::Data
            quote(attr.value_for_database)
          else
            quote(type_cast(attr.value_for_database))
          end
        end

        def sp_executesql_sql(sql, types, params, name)
          if name == 'EXPLAIN'
            params.each.with_index do |param, index|
              substitute_at_finder = /(@#{index})(?=(?:[^']|'[^']*')*$)/ # Finds unquoted @n values.
              sql.sub! substitute_at_finder, param.to_s
            end
          else
            types = quote(types.join(', '))
            params = params.map.with_index{ |p, i| "@#{i} = #{p}" }.join(', ') # Only p is needed, but with @i helps explain regexp.
            sql = "EXEC sp_executesql #{quote(sql)}"
            sql << ", #{types}, #{params}" unless params.empty?
          end
          sql
        end

        def raw_connection_do(sql)
          case @connection_options[:mode]
          when :dblib
            @connection.execute(sql).do
          when :odbc
            @connection.do(sql)
          end
        ensure
          @update_sql = false
        end

        # === SQLServer Specific (Identity Inserts) ===================== #

        def exec_insert_requires_identity?(sql, pk, binds)
          query_requires_identity_insert?(sql) if pk && binds.map(&:name).include?(pk)
        end

        def query_requires_identity_insert?(sql)
          if insert_sql?(sql)
            table_name = get_table_name(sql)
            id_column = identity_columns(table_name).first
            id_column && sql =~ /^\s*(INSERT|EXEC sp_executesql N'INSERT)[^(]+\([^)]*\b(#{id_column.name})\b,?[^)]*\)/i ? quote_table_name(table_name) : false
          else
            false
          end
        end

        def insert_sql?(sql)
          !(sql =~ /^\s*(INSERT|EXEC sp_executesql N'INSERT)/i).nil?
        end

        def identity_columns(table_name)
          schema_cache.columns(table_name).select(&:is_identity?)
        end

        # === SQLServer Specific (Selecting) ============================ #

        def raw_select(sql, name = 'SQL', binds = [], options = {})
          log(sql, name, binds) { _raw_select(sql, options) }
        end

        def _raw_select(sql, options = {})
          handle = raw_connection_run(sql)
          handle_to_names_and_values(handle, options)
        ensure
          finish_statement_handle(handle)
        end

        def raw_connection_run(sql)
          case @connection_options[:mode]
          when :dblib
            @connection.execute(sql)
          when :odbc
            block_given? ? @connection.run_block(sql) { |handle| yield(handle) } : @connection.run(sql)
          end
        end

        def handle_more_results?(handle)
          case @connection_options[:mode]
          when :dblib
          when :odbc
            handle.more_results
          end
        end

        def handle_to_names_and_values(handle, options = {})
          case @connection_options[:mode]
          when :dblib
            handle_to_names_and_values_dblib(handle, options)
          when :odbc
            handle_to_names_and_values_odbc(handle, options)
          end
        end

        def handle_to_names_and_values_dblib(handle, options = {})
          query_options = {}.tap do |qo|
            qo[:timezone] = ActiveRecord::Base.default_timezone || :utc
            qo[:as] = (options[:ar_result] || options[:fetch] == :rows) ? :array : :hash
          end
          results = handle.each(query_options)
          columns = lowercase_schema_reflection ? handle.fields.map { |c| c.downcase } : handle.fields
          options[:ar_result] ? ActiveRecord::Result.new(columns, results) : results
        end

        def handle_to_names_and_values_odbc(handle, options = {})
          @connection.use_utc = ActiveRecord::Base.default_timezone == :utc
          if options[:ar_result]
            columns = lowercase_schema_reflection ? handle.columns(true).map { |c| c.name.downcase } : handle.columns(true).map { |c| c.name }
            rows = handle.fetch_all || []
            ActiveRecord::Result.new(columns, rows)
          else
            case options[:fetch]
            when :all
              handle.each_hash || []
            when :rows
              handle.fetch_all || []
            end
          end
        end

        def finish_statement_handle(handle)
          case @connection_options[:mode]
          when :dblib
            handle.cancel if handle
          when :odbc
            handle.drop if handle && handle.respond_to?(:drop) && !handle.finished?
          end
          handle
        end

      end
    end
  end
end
