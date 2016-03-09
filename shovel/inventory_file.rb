require 'set'
require 'ostruct'

class Shovel
  class InventoryFile
    class Host < OpenStruct
      def initialize(name, attr_string)
        super()
        self.name = name
        parse(attr_string)
      end

      private

      def parse(attr_string)
        attr_string.scan(/(\S+)=(\S+)/).each do |name, value|
          self[name] = value
        end
        self
      end
    end

    def self.read(filename)
      new.parse(File.readlines(filename))
    end

    def host_set_names
      @hosts.keys
    end

    def [](host_set)
      @hosts[host_set]
    end

    def parse(document)
      @hosts = {}
      document.each do |line|
        case line
        when /^\s*(#|$)/
          next
        when /^\[([^\]]+)\]$/
          @current_host_set = $1
          next
        when /^([\w.-]+)(.*)/
          @current_host_set or raise "need a host set entry first"
          (@hosts[@current_host_set] ||= Set[]) << Host.new($1, $2)
        else
          raise "cannot parse #{line.inspect}"
        end
      end
      self
    end
  end
end
