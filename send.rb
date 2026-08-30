#!/usr/bin/env ruby
# frozen_string_literal: true

# Discover LocalSend devices, pick one with fzf, upload the given files.
#
# localsend-cli has no non-interactive "send to this device" flag, so this
# speaks the LocalSend v2 protocol directly. Ruby stdlib only.

require 'digest'
require 'fileutils'
require 'ipaddr'
require 'json'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'socket'
require 'uri'

MULTICAST = '224.0.0.167'
PORT = 53_317

module LocalSend
  module_function

  # yazi restores its UI the instant this process exits, wiping anything left on
  # screen, so hold the terminal until the user has actually read the message.
  def fatal(message)
    warn message
    if $stdin.tty?
      warn 'Press Enter to return to yazi...'
      $stdin.gets
    end
    exit 1
  end

  # LocalSend speaks mutual TLS: the server aborts the handshake without a
  # client certificate, and a device's fingerprint is that certificate's
  # SHA-256. Cached so the fingerprint stays stable across runs.
  def certificate
    return @certificate if @certificate

    dir = File.join(ENV['XDG_CACHE_HOME'] || File.expand_path('~/.cache'), 'localsend-yazi')
    FileUtils.mkdir_p(dir, mode: 0o700)
    cert_path = File.join(dir, 'cert.pem')
    key_path = File.join(dir, 'key.pem')

    if File.exist?(cert_path) && File.exist?(key_path)
      cert = OpenSSL::X509::Certificate.new(File.read(cert_path))
      key = OpenSSL::PKey::RSA.new(File.read(key_path))
    else
      cert, key = generate_certificate
      File.write(cert_path, cert.to_pem)
      File.write(key_path, key.to_pem, perm: 0o600)
    end

    @certificate = [cert, key, Digest::SHA256.hexdigest(cert.to_der).upcase]
  end

  def generate_certificate
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(128)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=LocalSend User')
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + (10 * 365 * 24 * 3600)
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    [cert, key]
  end

  def self_info
    @self_info ||= begin
      _cert, _key, fingerprint = certificate
      {
        'alias' => ENV['LOCALSEND_ALIAS'] || "#{Socket.gethostname} (yazi)",
        'version' => '2.1',
        'deviceModel' => 'Linux',
        'deviceType' => 'desktop',
        'fingerprint' => fingerprint,
        'port' => PORT,
        'protocol' => 'https',
        'download' => false
      }
    end
  end

  def http(device, read_timeout: 10, open_timeout: 3, write_timeout: 60)
    cert, key, = certificate
    h = Net::HTTP.new(device['ip'], device['port'] || PORT)
    if (device['protocol'] || 'https') == 'https'
      h.use_ssl = true
      h.cert = cert
      h.key = key
      # Every LocalSend device uses a self-signed certificate; trust is
      # established by the fingerprint shown on the receiving device.
      h.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    h.open_timeout = open_timeout
    h.read_timeout = read_timeout
    h.write_timeout = write_timeout
    h
  end

  # Announce ourselves on the group and collect the replies.
  def discover_multicast(timeout: 2.0)
    found = {}
    sock = UDPSocket.new
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1) if defined?(Socket::SO_REUSEPORT)
    begin
      sock.bind('0.0.0.0', PORT)
      sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP,
                      IPAddr.new(MULTICAST).hton + IPAddr.new('0.0.0.0').hton)
    rescue SystemCallError
      sock.close
      return found
    end

    sock.send(self_info.merge('announce' => true).to_json, 0, MULTICAST, PORT)
    reply = self_info.merge('announce' => false).to_json

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while (remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
      next unless IO.select([sock], nil, nil, [remaining, 0.3].min)

      data, addr = sock.recvfrom(8192)
      info = begin
        JSON.parse(data)
      rescue JSON::ParserError
        next
      end
      next unless info.is_a?(Hash)
      next if info['fingerprint'] == self_info['fingerprint']

      # Another scanner: answer so it sees us, but don't list it as a target.
      sock.send(reply, 0, addr[3], addr[1]) if info['announce']

      info['ip'] = addr[3]
      info['port'] ||= PORT
      found["#{info['ip']}:#{info['port']}"] = info
    end
    sock.close
    found
  end

  # POST our info to one host; a 200 means it is a LocalSend device.
  def register(ip)
    %w[https http].each do |scheme|
      device = { 'ip' => ip, 'port' => PORT, 'protocol' => scheme }
      begin
        res = http(device, read_timeout: 1.5, open_timeout: 1.5)
              .post('/api/localsend/v2/register', self_info.to_json,
                    'Content-Type' => 'application/json')
        next unless res.code == '200'

        info = JSON.parse(res.body)
        info['ip'] = ip
        info['port'] ||= PORT
        info['protocol'] ||= scheme
        return info
      rescue StandardError
        next
      end
    end
    nil
  end

  # Fallback when nothing answers the multicast: register against every host
  # on the local /24.
  def discover_sweep
    mine = local_ip
    return {} unless mine

    prefix = mine.rpartition('.').first
    found = {}
    mutex = Mutex.new

    (1..254).map do |i|
      ip = "#{prefix}.#{i}"
      next if ip == mine

      Thread.new do
        info = register(ip)
        mutex.synchronize { found["#{ip}:#{info['port']}"] = info } if info
      end
    end.compact.each(&:join)

    found
  end

  def local_ip
    UDPSocket.open do |s|
      s.connect('1.1.1.1', 80)
      s.addr.last
    end
  rescue SystemCallError
    nil
  end

  def pick(devices)
    keys = devices.keys
    lines = keys.each_with_index.map do |k, i|
      d = devices[k]
      model = d['deviceModel'] || d['deviceType'] || '?'
      "#{i}\t#{d['alias']} [#{model}] #{k}"
    end

    # fzf draws on /dev/tty, so piping its stdin and stdout still shows the UI.
    out = IO.popen(['fzf', '--delimiter=\t', '--with-nth=2', '--height=100%',
                    '--prompt=LocalSend > ', '--header=Enter to send, Esc to cancel'], 'r+') do |io|
      io.write(lines.join("\n"))
      io.close_write
      io.read
    end
    return nil unless $?.success?
    return nil if out.nil? || out.strip.empty?

    devices[keys[out.split("\t").first.to_i]]
  end

  def send_files(device, paths)
    files = paths.to_h do |p|
      id = SecureRandom.hex(16)
      [id, { 'id' => id, 'fileName' => File.basename(p), 'size' => File.size(p),
             'fileType' => 'application/octet-stream', 'preview' => nil, :path => p }]
    end

    payload = {
      'info' => self_info,
      'files' => files.transform_values { |m| m.reject { |k, _| k == :path } }
    }

    warn "Waiting for #{device['alias']} to accept..."
    # The receiver blocks on its accept prompt, so allow for a human.
    res = http(device, read_timeout: 300)
          .post('/api/localsend/v2/prepare-upload', payload.to_json,
                'Content-Type' => 'application/json')

    case res.code
    when '200' then nil
    when '401' then fatal 'Device requires a PIN — not supported, send from the LocalSend app.'
    when '403' then fatal 'Device declined the request.'
    else fatal "prepare-upload failed: HTTP #{res.code} #{res.body.to_s[0, 200]}"
    end

    session = JSON.parse(res.body)
    tokens = session['files'] || {}

    files.each_with_index do |(id, meta), n|
      label = "[#{n + 1}/#{files.size}] #{meta['fileName']}"
      unless tokens[id]
        puts "#{label}: declined by device"
        next
      end

      puts "#{label} (#{meta['size']} bytes) -> #{device['alias']}"
      upload(device, session['sessionId'], id, tokens[id], meta)
    end
  end

  def upload(device, session_id, file_id, token, meta)
    query = URI.encode_www_form(sessionId: session_id, fileId: file_id, token: token)
    req = Net::HTTP::Post.new("/api/localsend/v2/upload?#{query}")
    req['Content-Type'] = 'application/octet-stream'
    req.content_length = meta['size']

    File.open(meta[:path], 'rb') do |f|
      req.body_stream = f
      # No read or write timeout: a large file over a weak link may legitimately
      # stall for a long time without the transfer being dead.
      res = http(device, read_timeout: nil, write_timeout: nil).request(req)
      if %w[200 204].include?(res.code)
        puts '  done'
      else
        puts "  failed: HTTP #{res.code}"
      end
    end
  rescue StandardError => e
    puts "  failed: #{e.class}: #{e.message}"
  end
end

if __FILE__ == $PROGRAM_NAME
  paths = ARGV
  LocalSend.fatal 'No files given.' if paths.empty?
  paths.each do |p|
    LocalSend.fatal "#{p} is a directory — LocalSend sends files only." if File.directory?(p)
    LocalSend.fatal "#{p} does not exist." unless File.file?(p)
  end

  begin
    puts 'Scanning for LocalSend devices...'
    devices = LocalSend.discover_multicast
    if devices.empty?
      puts 'No multicast reply, sweeping the local subnet...'
      devices = LocalSend.discover_sweep
    end
    LocalSend.fatal 'No LocalSend devices found. Is the app open and on the same network?' if devices.empty?

    target = LocalSend.pick(devices)
    exit if target.nil?

    LocalSend.send_files(target, paths)
  rescue Interrupt
    exit 130
  rescue StandardError => e
    LocalSend.fatal "#{e.class}: #{e.message}"
  end
end
