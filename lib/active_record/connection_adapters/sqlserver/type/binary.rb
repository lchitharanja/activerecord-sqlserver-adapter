module ActiveRecord
  module ConnectionAdapters
    module SQLServer
      module Type
        class Binary < ActiveRecord::Type::Binary

          def cast_value(value)
            if value.class.to_s == 'String' and !value.frozen?
              value.force_encoding(Encoding::BINARY) =~ /[^[:xdigit:]]/ ? value : [value].pack('H*')
            else
              value
            end
          end

          def type
            :binary_basic
          end

          def sqlserver_type
            'binary'.tap do |type|
              type << "(#{limit})" if limit
            end
          end

        end
      end
    end
  end
end
