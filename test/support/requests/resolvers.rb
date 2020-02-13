# frozen_string_literal: true

module Requests
  module Resolvers
    SessionWithPool = Class.new(HTTPX::Session) do
      def pool
        @pool ||= HTTPX::Pool.new
      end
    end

    {
      native: { cache: false },
      system: { cache: false },
      https: { uri: ENV["HTTPX_RESOLVER_URI"], cache: false },
    }.each do |resolver, options|
      define_method :"test_multiple_#{resolver}_resolver_errors" do
        2.times do |i|
          session = SessionWithPool.new
          unknown_uri = "http://www.sfjewjfwigiewpgwwg-native-#{i}.com"
          response = session.get(unknown_uri, resolver_class: resolver, resolver_options: options)
          assert response.is_a?(HTTPX::ErrorResponse), "should be a response error"
          assert response.error.is_a?(HTTPX::ResolveError), "should be a resolving error"
        end
      end

      define_method :"test_#{resolver}_resolver_request" do
        session = SessionWithPool.new
        uri = build_uri("/get")
        response = session.head(uri, resolver_class: resolver, resolver_options: options)
        verify_status(response, 200)
      end
    end
  end
end