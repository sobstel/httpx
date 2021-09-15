# frozen_string_literal: true

require_relative "test_helper"

class ResponseTest < Minitest::Test
  include HTTPX
  include ResponseHelpers

  if RUBY_VERSION >= "3.0.0"
    require_relative "extensions/response_pattern_match"
    include ResponsePatternMatchTests
  end

  def test_response_status
    r1 = Response.new(request, 200, "1.1", {})
    assert r1.status == 200, "unexpected status code (#{r1.status})"
    r2 = Response.new(request, "200", "1.1", {})
    assert r2.status == 200, "unexpected status code (#{r2.status})"
  end

  def test_response_headers
    assert resource.headers.is_a?(Headers), "headers should have been coerced"
  end

  def test_response_body_write
    assert resource.body.empty?, "body should be empty after init"
    resource << "data"
    assert resource.body == "data", "body should have been updated"
  end

  def test_response_error
    r1 = Response.new(request, 200, "2.0", {})
    assert r1.error.nil?
    r2 = Response.new(request, 404, "2.0", {})
    assert !r2.error.nil?
    assert r2.error.is_a?(HTTPError)
  end

  def test_response_raise_for_status
    r1 = Response.new(request, 200, "2.0", {})
    assert r1.raise_for_status == r1
    r2 = Response.new(request, 302, "2.0", {})
    assert r2.raise_for_status == r2
    r3 = Response.new(request, 404, "2.0", {})
    error = assert_raises(HTTPError) { r3.raise_for_status }
    assert error.status == 404
    r4 = Response.new(request, 500, "2.0", {})
    error = assert_raises(HTTPError) { r4.raise_for_status }
    assert error.status == 500
  end

  def test_response_body_to_s
    body1 = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    assert body1 == "", "body should be empty"
    assert body1.empty?, "body must be empty after initialization"
    body1.write("foo")
    assert body1 == "foo", "body must be updated"
    body2 = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    body2.write("foo")
    body2.write("bar")
    assert body2 == "foobar", "body buffers chunks"

    body3 = Response::Body.new(Response.new(request("head"), 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    assert body3.empty?, "body must be empty after initialization"
    assert body3 == "", "HEAD request body must be empty (#{body3})"

    text = +"heãd"
    text.force_encoding(Encoding::BINARY)
    body4 = Response::Body.new(Response.new(request, 200, "2.0", { "content-type" => "text/html; charset=utf" }),
                               Options.new(body_threshold_size: 1024))
    body4.write(text)
    req_text = body4.to_s
    assert text == req_text, "request body must be in original encoding (#{req_text})"

    payload = "a" * 2048
    body5 = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    body5.write(payload)
    assert body5 == "a" * 2048, "body messed up with file"
    assert body5 == StringIO.new("a" * 2048), "body messed up with file"
  end

  def test_response_body_copy_to_memory
    payload = "a" * 512
    body = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    body.write(payload)

    memory = StringIO.new
    body.copy_to(memory)
    assert memory.string == payload, "didn't copy all bytes (expected #{payload.bytesize}, was #{memory.size})"
    body.close
  end

  def test_response_body_copy_to_file
    payload = "a" * 2048
    body = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    body.write(payload)

    file = Tempfile.new("httpx-file-buffer")
    body.copy_to(file)
    assert File.read(file.path) == payload, "didn't copy all bytes (expected #{payload.bytesize}, was #{File.size(file.path)})"
    body.close
    file.unlink
  end

  def test_response_body_read
    body1 = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    body1.write("foo")
    assert body1.bytesize == 3
    assert body1.read(1), "f"
    assert body1.read(1), "o"
    assert body1.read(1), "o"
  end

  def test_response_body_each
    body1 = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    body1.write("foo")
    assert body1.each.to_a == %w[foo], "must yield buffer"
    body2 = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 1024))
    body2.write("foo")
    body2.write("bar")
    assert body2.each.to_a == %w[foobar], "must yield buffers"
  end

  def test_response_body_buffer
    body = Response::Body.new(Response.new(request, 200, "2.0", {}), Options.new(body_threshold_size: 10))
    body.extend(Module.new do
      attr_reader :buffer
    end)
    assert body.buffer.nil?, "body should not buffer anything"
    body.write("hello")
    assert body.buffer.is_a?(StringIO), "body should buffer to memory"
    body.write(" world")
    assert body.buffer.is_a?(Tempfile), "body should buffer to file after going over threshold"
  end

  def test_response_decoders
    json_response = Response.new(request, 200, "2.0", { "content-type" => "application/json" })
    json_response << %({"a": "b"})
    assert json_response.json == { "a" => "b" }
    assert json_response.json(symbolize_names: true) == { :a => "b" }
    json_response << "bogus"
    assert_raises(JSON::ParserError) { json_response.json }
    err = assert_raises(HTTPX::Error) { json_response.form }
    assert err.message == "invalid form mime type (application/json)"

    form_response = Response.new(request, 200, "2.0", { "content-type" => "application/x-www-form-urlencoded" })
    form_response << "a=b&c=d"
    assert form_response.form == { "a" => "b", "c" => "d" }
    err = assert_raises(HTTPX::Error) { form_response.json }
    assert err.message == "invalid json mime type (application/x-www-form-urlencoded)"
    form_response << "богус"
    assert_raises(ArgumentError) { form_response.form }

    form2_response = Response.new(request, 200, "2.0", { "content-type" => "application/x-www-form-urlencoded" })
    form2_response << "a[]=b&a[]=c&d[e]=f&g[h][i][j]=k&l[m][][n]=o&l[m][][p]=q&l[m][][n]=r&s[=t"
    assert form2_response.form == {
      "a" => %w[b c],
      "d" => { "e" => "f" },
      "g" => { "h" => { "i" => { "j" => "k" } } },
      "l" => { "m" => [{ "n" => "o", "p" => "q" }, { "n" => "r" }] },
      "s[" => "t",
    }

    form3_response = Response.new(request, 200, "2.0", { "content-type" => "application/x-www-form-urlencoded" })
    form3_response << "a[][]=3"
    assert form3_response.form == { "a" => [["3"]] }

    form4_response = Response.new(request, 200, "2.0", { "content-type" => "application/x-www-form-urlencoded" })
    form4_response << "[]"
    assert form4_response.form == {}

    error = assert_raises(HTTPX::Error) { form2_response.__send__(:decode, "bla") }
    assert error.message.include?("no decoder available for"), "failed with unexpected error"
  end

  private

  def request(verb = :get, uri = "http://google.com")
    Request.new(verb, uri)
  end

  def response(*args)
    Response.new(*args)
  end

  def resource
    @resource ||= Response.new(request, 200, "2.0", {})
  end
end
