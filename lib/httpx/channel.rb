# frozen_string_literal: true

require "forwardable"
require "httpx/io"
require "httpx/buffer"

module HTTPX
  # The Channel entity can be watched for IO events.
  #
  # It contains the +io+ object to read/write from, and knows what to do when it can.
  #
  # It defers connecting until absolutely necessary. Connection should be triggered from
  # the IO selector (until then, any request will be queued).
  #
  # A channel boots up its parser after connection is established. All pending requests
  # will be redirected there after connection.
  #
  # A channel can be prevented from closing by the parser, that is, if there are pending
  # requests. This will signal that the channel was prematurely closed, due to a possible
  # number of conditions:
  #
  # * Remote peer closed the connection ("Connection: close");
  # * Remote peer doesn't support pipelining;
  #
  # A channel may also route requests for a different host for which the +io+ was connected
  # to, provided that the IP is the same and the port and scheme as well. This will allow to
  # share the same socket to send HTTP/2 requests to different hosts.
  # TODO: For this to succeed, the certificates sent by the servers to the client must be
  #       identical (or match both hosts).
  #
  class Channel
    extend Forwardable
    include Registry
    include Loggable
    include Callbacks

    require "httpx/channel/http2"
    require "httpx/channel/http1"

    BUFFER_SIZE = 1 << 14

    class << self
      def by(uri, options)
        io = case uri.scheme
             when "http"
               IO.registry("tcp").new(uri.host, uri.port, options)
             when "https"
               IO.registry("ssl").new(uri.host, uri.port, options)
             else
               raise Error, "#{uri}: #{uri.scheme}: unrecognized channel"
        end
        new(io, options)
      end
    end

    def_delegator :@io, :closed?

    def_delegator :@write_buffer, :empty?

    def initialize(io, options)
      @io = io
      @options = Options.new(options)
      @window_size = @options.window_size
      @read_buffer = Buffer.new(BUFFER_SIZE)
      @write_buffer = Buffer.new(BUFFER_SIZE)
      @pending = []
      @state = :idle
    end

    def match?(uri)
      ip = begin
             TCPSocket.getaddress(uri.host)
           rescue StandardError
             uri.host
           end

      ip == @io.ip &&
        uri.port == @io.port &&
        uri.scheme == @io.scheme
    end

    def interests
      return :w if @state == :idle
      readable = !@read_buffer.full?
      writable = !@write_buffer.empty?
      if readable
        writable ? :rw : :r
      else
        writable ? :w : :r
      end
    end

    def to_io
      case @state
      when :idle
        transition(:open)
      end
      @io.to_io
    end

    def close(hard = false)
      pr = @parser
      transition(:closed)
      return true if hard
      if pr && pr.empty?
        pr.close
        @parser = nil
      else
        transition(:idle)
        @parser = pr
        parser.reenqueue!
        return false
      end
      true
    end

    def send(request, **args)
      if @parser && !@write_buffer.full?
        parser.send(request, **args)
      else
        @pending << [request, args]
      end
    end

    def call
      return if @state == :closed
      catch(:called) do
        dread
        dwrite
        parser.consume
      end
      nil
    end

    def upgrade_parser(protocol)
      @parser.close if @parser
      @parser = build_parser(protocol)
    end

    private

    def dread(wsize = @window_size)
      loop do
        siz = @io.read(wsize, @read_buffer)
        throw(:close, self) unless siz
        return if siz.zero?
        log { "READ: #{siz} bytes..." }
        parser << @read_buffer.to_s
      end
    end

    def dwrite
      loop do
        return if @write_buffer.empty?
        siz = @io.write(@write_buffer)
        throw(:close, self) unless siz
        log { "WRITE: #{siz} bytes..." }
        return if siz.zero?
      end
    end

    def send_pending
      while !@write_buffer.full? && (req_args = @pending.shift)
        request, args = req_args
        parser.send(request, **args)
      end
    end

    def parser
      @parser ||= build_parser
    end

    def build_parser(protocol = @io.protocol)
      parser = registry(protocol).new(@write_buffer, @options)
      parser.inherit_callbacks(self)
      parser.on(:close) { throw(:close, self) }
      parser
    end

    def transition(nextstate)
      case nextstate
      # when :idle

      when :open
        return if @state == :closed
        @io.connect
        return if @io.closed?
        send_pending
      when :closed
        return if @state == :idle
        @io.close
        @read_buffer.clear
        @write_buffer.clear
      end
      @state = nextstate
    end
  end
end
