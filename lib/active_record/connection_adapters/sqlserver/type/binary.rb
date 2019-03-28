module ActiveRecord
  module ConnectionAdapters
    module SQLServer
      module Type
        class Binary < ActiveRecord::Type::Binary

          def cast_value(value)
            value.force_encoding(Encoding::BINARY) =~ /[^[:xdigit:]]/ ? value : [value].pack('H*')
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
