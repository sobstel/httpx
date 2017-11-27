# frozen_string_literal: true

require "httpx/headers"

module HTTPX
  class Options
    @default_timeout_class    = HTTPX::Timeout::Null

    class << self
      attr_accessor :default_timeout_class

      def new(options = {})
        return options if options.is_a?(self)
        super
      end

      def defined_options
        @defined_options ||= []
      end

      protected

      def def_option(name, &interpreter)
        defined_options << name.to_sym
        interpreter ||= lambda { |v| v }

        attr_accessor name
        protected :"#{name}="

        define_method(:"with_#{name}") do |value|
          dup { |opts| opts.send(:"#{name}=", instance_exec(value, &interpreter)) }
        end
      end
    end

    def initialize(options = {}) # rubocop:disable Style/OptionHash
      defaults = {
        :proxy              => {},
        :timeout_class      => self.class.default_timeout_class,
        :timeout_options    => {},
        :ssl                => {},
        :keep_alive_timeout => 5,
        :headers            => {},
        :cookies            => {},
      }

      opts_w_defaults = defaults.merge(options)
      opts_w_defaults[:headers] = HTTPX::Headers.new(opts_w_defaults[:headers])
      opts_w_defaults.each { |(k, v)| self[k] = v }
    end

    def_option :headers do |headers|
      self.headers.merge(headers)
    end

    def_option :cookies do |cookies|
      cookies.each_with_object(self.cookies.dup) do |(k, v), jar|
        cookie = k.is_a?(Cookie) ? k : Cookie.new(k.to_s, v.to_s)
        jar[cookie.name] = cookie.cookie_value
      end
    end

    %w[
      proxy params form json body follow response
      ssl_context ssl
      keep_alive_timeout timeout_class timeout_options
    ].each do |method_name|
      def_option method_name
    end

    def follow=(value)
      @follow =
        case
        when !value                    then nil
        when true == value             then {}
        when value.respond_to?(:fetch) then value
        else argument_error! "Unsupported follow options: #{value}"
        end
    end

    def merge(other)
      h1 = to_hash
      h2 = other.to_hash

      merged = h1.merge(h2) do |k, v1, v2|
        case k
        when :headers
          v1.merge(v2)
        else
          v2
        end
      end

      self.class.new(merged)
    end

    def to_hash
      hash_pairs = self.class.
                   defined_options.
                   flat_map { |opt_name| [opt_name, send(opt_name)] }
      Hash[*hash_pairs]
    end

    def dup
      dupped = super
      yield(dupped) if block_given?
      dupped
    end

    protected

    def []=(option, val)
      send(:"#{option}=", val)
    end

    private

    def argument_error!(message)
      raise(Error, message, caller(1..-1))
    end
  end
end
