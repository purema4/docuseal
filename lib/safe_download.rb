# frozen_string_literal: true

# Downloads a file from a user supplied URL with SSRF protections:
# - HTTPS on port 443 only
# - every resolved address must be public (no loopback, private, link-local,
#   CGNAT, multicast, reserved or cloud metadata ranges)
# - the connection is pinned to the validated IP to prevent DNS rebinding
# - redirects are re-validated and capped
# - response size and timeouts are capped
module SafeDownload
  Error = Class.new(StandardError)

  MAX_REDIRECTS = 3
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 20

  BLOCKED_RANGES = %w[
    0.0.0.0/8
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.0.0.0/24
    192.0.2.0/24
    192.88.99.0/24
    192.168.0.0/16
    198.18.0.0/15
    198.51.100.0/24
    203.0.113.0/24
    224.0.0.0/4
    240.0.0.0/4
    255.255.255.255/32
    ::/128
    ::1/128
    ::ffff:0:0/96
    64:ff9b::/96
    100::/64
    2001::/23
    2001:db8::/32
    2002::/16
    fc00::/7
    fe80::/10
    fec0::/10
    ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  module_function

  def call(url, max_bytes:, redirects_left: MAX_REDIRECTS)
    uri = parse_uri(url)

    ip = resolve_public_ip!(uri.host)

    response_body = nil

    Net::HTTP.start(uri.host, 443, use_ssl: true, ipaddr: ip,
                                   open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT,
                                   ssl_timeout: OPEN_TIMEOUT) do |http|
      request = Net::HTTP::Get.new(uri)
      request['Accept-Encoding'] = 'identity'

      http.request(request) do |response|
        case response
        when Net::HTTPRedirection
          raise Error, 'Too many redirects' if redirects_left <= 0

          location = URI.join(uri.to_s, response['location'].to_s).to_s

          return call(location, max_bytes:, redirects_left: redirects_left - 1)
        when Net::HTTPSuccess
          response_body = read_limited_body(response, max_bytes)
        else
          raise Error, "Unable to download file: HTTP #{response.code}"
        end
      end
    end

    response_body
  rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, EOFError
    raise Error, 'Unable to download file'
  end

  def parse_uri(url)
    uri = URI.parse(url.to_s)

    raise Error, 'Only HTTPS URLs are allowed' unless uri.is_a?(URI::HTTPS)
    raise Error, 'Only port 443 is allowed' unless uri.port == 443
    raise Error, 'URL host is required' if uri.host.blank?
    raise Error, 'URL credentials are not allowed' if uri.userinfo.present?

    uri
  rescue URI::InvalidURIError
    raise Error, 'Invalid URL'
  end

  def resolve_public_ip!(host)
    addresses = resolve(host)

    raise Error, 'Unable to resolve host' if addresses.blank?

    addresses.each do |address|
      raise Error, 'URL resolves to a disallowed address' unless public_ip?(address)
    end

    addresses.first
  end

  def resolve(host)
    host = host.delete_prefix('[').delete_suffix(']')

    return [host] if ip_literal?(host)

    Addrinfo.getaddrinfo(host, 443, nil, :STREAM).map(&:ip_address).uniq
  rescue SocketError
    []
  end

  def ip_literal?(host)
    IPAddr.new(host)

    true
  rescue IPAddr::InvalidAddressError
    false
  end

  def public_ip?(address)
    ip = IPAddr.new(address.to_s.sub(/%.*\z/, ''))

    BLOCKED_RANGES.none? { |range| range.family == ip.family && range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def read_limited_body(response, max_bytes)
    raise Error, 'File is too large' if response.content_length.to_i > max_bytes

    body = +''

    response.read_body do |chunk|
      body << chunk

      raise Error, 'File is too large' if body.bytesize > max_bytes
    end

    body.b
  end
end
