# frozen_string_literal: true

require "forwardable"
require "resolv"

module HTTPX
  class Resolver::Native
    extend Forwardable
    include Resolver::ResolverMixin

    RESOLVE_TIMEOUT = 5
    RECORD_TYPES = {
      "A" => Resolv::DNS::Resource::IN::A,
      "AAAA" => Resolv::DNS::Resource::IN::AAAA,
    }.freeze

    DEFAULTS = if RUBY_VERSION < "2.2"
      {
        **Resolv::DNS::Config.default_config_hash,
        packet_size: 512,
        timeouts: RESOLVE_TIMEOUT,
        record_types: RECORD_TYPES.keys,
      }.freeze
    else
      {
        nameserver: nil,
        **Resolv::DNS::Config.default_config_hash,
        packet_size: 512,
        timeouts: RESOLVE_TIMEOUT,
        record_types: RECORD_TYPES.keys,
      }.freeze
    end

    DNS_PORT = 53

    def_delegator :@connections, :empty?

    def initialize(_, options)
      @options = Options.new(options)
      @ns_index = 0
      @resolver_options = Resolver::Options.new(DEFAULTS.merge(@options.resolver_options || {}))
      @nameserver = @resolver_options.nameserver
      @_timeouts = Array(@resolver_options.timeouts)
      @timeouts = Hash.new { |timeouts, host| timeouts[host] = @_timeouts.dup }
      @_record_types = Hash.new { |types, host| types[host] = @resolver_options.record_types.dup }
      @connections = []
      @queries = {}
      @read_buffer = Buffer.new(@resolver_options.packet_size)
      @write_buffer = Buffer.new(@resolver_options.packet_size)
      @state = :idle
    end

    def close
      transition(:closed)
    end

    def closed?
      @state == :closed
    end

    def to_io
      case @state
      when :idle
        transition(:open)
      when :closed
        transition(:idle)
        transition(:open)
      end
      resolve if @queries.empty?
      @io.to_io
    end

    def call
      case @state
      when :open
        consume
      end
      nil
    rescue Errno::EHOSTUNREACH => e
      @ns_index += 1
      if @ns_index < @nameserver.size
        transition(:idle)
      else
        @queries.each do |host, connection|
          emit_resolve_error(connection, host, e)
        end
      end
    end

    def interests
      readable = !@read_buffer.full?
      writable = !@write_buffer.empty?
      if readable
        writable ? :rw : :r
      else
        writable ? :w : :r
      end
    end

    def <<(connection)
      return if early_resolve(connection)

      if @nameserver.nil?
        ex = ResolveError.new("Can't resolve #{connection.uri.host}: no nameserver")
        ex.set_backtrace(caller)
        emit(:error, connection, ex)
      else
        @connections << connection
      end
    end

    def timeout
      @start_timeout = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      hosts = @queries.keys
      @timeouts.values_at(*hosts).reject(&:empty?).map(&:first).min
    end

    private

    def consume
      dread
      do_retry
      dwrite
    end

    def do_retry
      return if @queries.empty?

      loop_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_timeout
      connections = []
      queries = {}
      while (query = @queries.shift)
        h, connection = query
        host = connection.uri.host
        timeout = (@timeouts[host][0] -= loop_time)
        unless timeout.negative?
          queries[h] = connection
          next
        end
        @timeouts[host].shift
        if @timeouts[host].empty?
          @timeouts.delete(host)
          emit_resolve_error(connection, host)
          return
        else
          connections << connection
          log(label: "resolver: ") do
            "timeout after #{prev_timeout}s, retry(#{timeouts.first}) #{host}..."
          end
        end
      end
      @queries = queries
      connections.each { |ch| resolve(ch) }
    end

    def dread(wsize = @read_buffer.limit)
      loop do
        siz = @io.read(wsize, @read_buffer)
        unless siz
          emit(:close)
          return
        end
        return if siz.zero?

        log(label: "resolver: ") { "READ: #{siz} bytes..." }
        parse(@read_buffer.to_s)
      end
    end

    def dwrite
      loop do
        return if @write_buffer.empty?

        siz = @io.write(@write_buffer)
        unless siz
          emit(:close)
          return
        end
        log(label: "resolver: ") { "WRITE: #{siz} bytes..." }
        return if siz.zero?
      end
    end

    def parse(buffer)
      begin
        addresses = Resolver.decode_dns_answer(buffer)
      rescue Resolv::DNS::DecodeError => e
        hostname, connection = @queries.first
        if @_record_types[hostname].empty?
          emit_resolve_error(connection, hostname, e)
          return
        end
      end

      if addresses.empty?
        hostname, connection = @queries.first
        @_record_types[hostname].shift
        if @_record_types[hostname].empty?
          @_record_types.delete(hostname)
          emit_resolve_error(connection, hostname)
          return
        end
      else
        address = addresses.first
        connection = @queries.delete(address["name"])
        return unless connection # probably a retried query for which there's an answer

        if address.key?("alias") # CNAME
          if early_resolve(connection, hostname: address["alias"])
            @connections.delete(connection)
          else
            resolve(connection, address["alias"])
            @queries.delete(address["name"])
            return
          end
        else
          @connections.delete(connection)
          Resolver.cached_lookup_set(connection.uri.host, addresses)
          emit_addresses(connection, addresses.map { |addr| addr["data"] })
        end
      end
      return emit(:close) if @connections.empty?

      resolve
    end

    def resolve(connection = @connections.first, hostname = nil)
      raise Error, "no URI to resolve" unless connection
      return unless @write_buffer.empty?

      hostname = hostname || @queries.key(connection) || connection.uri.host
      @queries[hostname] = connection
      type = @_record_types[hostname].first
      log(label: "resolver: ") { "query #{type} for #{hostname}" }
      begin
        @write_buffer << Resolver.encode_dns_query(hostname, type: RECORD_TYPES[type])
      rescue Resolv::DNS::EncodeError => e
        emit_resolve_error(connection, hostname, e)
      end
    end

    def build_socket
      return if @io

      ip, port = @nameserver[@ns_index]
      port ||= DNS_PORT
      uri = URI::Generic.build(scheme: "udp", port: port)
      uri.hostname = ip
      type = IO.registry(uri.scheme)
      log(label: "resolver: ") { "server: #{uri}..." }
      @io = type.new(uri, [IPAddr.new(ip)], @options)
    end

    def transition(nextstate)
      case nextstate
      when :idle
        if @io
          @io.close
          @io = nil
        end
        @timeouts.clear
      when :open
        return unless @state == :idle

        build_socket
        @io.connect
        return unless @io.connected?
      when :closed
        return unless @state == :open

        @io.close if @io
      end
      @state = nextstate
    end
  end
end
