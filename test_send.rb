#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline checks: the two requests send_files makes, and cert stability.
# Run with: ruby test_send.rb

require 'json'
require 'socket'
require 'tmpdir'
require_relative 'send'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

# A two-request HTTP stub: answers prepare-upload with a session, then accepts
# the upload. Records both so the test can inspect what was actually sent.
def stub_receiver
  server = TCPServer.new('127.0.0.1', 0)
  seen = {}

  thread = Thread.new do
    2.times do
      conn = server.accept
      request_line = conn.gets
      headers = {}
      while (line = conn.gets) && line != "\r\n"
        key, value = line.split(':', 2)
        headers[key.downcase] = value.strip
      end
      body = headers['content-length'] ? conn.read(headers['content-length'].to_i) : ''

      if request_line.include?('prepare-upload')
        seen[:prepare] = JSON.parse(body)
        file_id = seen[:prepare]['files'].keys.first
        seen[:file_id] = file_id
        payload = { 'sessionId' => 'S1', 'files' => { file_id => 'TOK' } }.to_json
        conn.print("HTTP/1.1 200 OK\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}")
      else
        seen[:upload_line] = request_line
        seen[:upload_body] = body
        conn.print("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      end
      conn.close
    end
  end

  [server.addr[1], seen, thread]
end

def test_send_protocol
  port, seen, thread = stub_receiver

  Dir.mktmpdir do |dir|
    path = File.join(dir, 'probe.txt')
    File.write(path, 'hello')

    device = { 'ip' => '127.0.0.1', 'port' => port, 'protocol' => 'http', 'alias' => 'stub' }
    LocalSend.send_files(device, [path])
    thread.join(5)

    meta = seen[:prepare]['files'][seen[:file_id]]
    assert(meta['fileName'] == 'probe.txt', "fileName was #{meta['fileName'].inspect}")
    assert(meta['size'] == 5, "size was #{meta['size'].inspect}")
    assert(!meta.key?('path'), 'internal :path leaked into the request')
    assert(seen[:prepare]['info']['version'] == '2.1', 'info.version wrong')

    assert(seen[:upload_line].include?('sessionId=S1'), "upload query: #{seen[:upload_line]}")
    assert(seen[:upload_line].include?('token=TOK'), "upload query: #{seen[:upload_line]}")
    assert(seen[:upload_line].include?("fileId=#{seen[:file_id]}"), "upload query: #{seen[:upload_line]}")
    assert(seen[:upload_body] == 'hello', "upload body was #{seen[:upload_body].inspect}")
  end
end

def test_cert_fingerprint_is_stable
  Dir.mktmpdir do |dir|
    ENV['XDG_CACHE_HOME'] = dir
    LocalSend.instance_variable_set(:@certificate, nil)
    _cert, _key, first = LocalSend.certificate

    LocalSend.instance_variable_set(:@certificate, nil)
    _cert, _key, second = LocalSend.certificate

    assert(first == second, "fingerprint changed between runs: #{first} != #{second}")
    assert(first.match?(/\A[0-9A-F]{64}\z/), "fingerprint #{first.inspect} is not 64 uppercase hex chars")
  end
end

test_send_protocol
test_cert_fingerprint_is_stable
puts 'ok'
