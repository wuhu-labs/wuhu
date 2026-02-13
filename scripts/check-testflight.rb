#!/usr/bin/env ruby
# Check TestFlight Build Status
# Usage: ./scripts/check-testflight.rb [--watch] [--json]

require 'json'
require 'net/http'
require 'openssl'
require 'base64'
require 'time'

ASC_KEY_ID = "3U39ZA4G2A"
ASC_ISSUER_ID = "d782de6f-d166-4df4-8124-a96926af646b"
ASC_KEY_PATH = File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{ASC_KEY_ID}.p8")
BUNDLE_ID = "ms.liu.wuhu.ios"
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

def base64url_encode(data)
  Base64.strict_encode64(data).tr('+/', '-_').delete('=')
end

def generate_token
  private_key = OpenSSL::PKey::EC.new(File.read(ASC_KEY_PATH))
  
  header = { alg: "ES256", kid: ASC_KEY_ID, typ: "JWT" }
  now = Time.now.to_i
  payload = {
    iss: ASC_ISSUER_ID,
    iat: now,
    exp: now + 1200,
    aud: "appstoreconnect-v1"
  }
  
  header_b64 = base64url_encode(header.to_json)
  payload_b64 = base64url_encode(payload.to_json)
  signing_input = "#{header_b64}.#{payload_b64}"
  
  signature = private_key.sign("SHA256", signing_input)
  
  # Convert DER signature to raw R+S format (64 bytes)
  asn1 = OpenSSL::ASN1.decode(signature)
  r = asn1.value[0].value.to_s(2).rjust(32, "\x00")[-32..-1]
  s = asn1.value[1].value.to_s(2).rjust(32, "\x00")[-32..-1]
  raw_sig = r + s
  
  sig_b64 = base64url_encode(raw_sig)
  "#{signing_input}.#{sig_b64}"
end

def api_request(path, params = {})
  uri = URI("#{BASE_URL}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{generate_token}"
  
  response = http.request(request)
  JSON.parse(response.body)
end

def get_app_id
  result = api_request("/apps", { "filter[bundleId]" => BUNDLE_ID })
  return nil if result["data"].nil? || result["data"].empty?
  result["data"][0]["id"]
end

def get_builds(app_id, limit = 5)
  result = api_request("/builds", {
    "filter[app]" => app_id,
    "limit" => limit,
    "sort" => "-uploadedDate"
  })
  result["data"] || []
end

def check_builds(json_output: false)
  app_id = get_app_id
  if app_id.nil?
    puts "❌ Could not find app with bundle ID: #{BUNDLE_ID}"
    return false
  end
  
  builds = get_builds(app_id)
  
  if json_output
    builds.each do |build|
      attr = build["attributes"]
      puts({
        version: attr["version"],
        build: attr["buildNumber"],
        state: attr["processingState"],
        uploaded: attr["uploadedDate"]
      }.to_json)
    end
    return true
  end
  
  puts "📱 TestFlight Builds for Wuhu (#{BUNDLE_ID})"
  puts "=" * 50
  puts
  
  status_emoji = {
    "PROCESSING" => "⏳",
    "FAILED" => "❌",
    "INVALID" => "⚠️",
    "VALID" => "✅"
  }
  
  builds.each do |build|
    attr = build["attributes"]
    state = attr["processingState"] || "UNKNOWN"
    emoji = status_emoji[state] || "❓"
    
    uploaded = attr["uploadedDate"]
    if uploaded
      dt = Time.parse(uploaded)
      uploaded = dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    end
    
    puts "Version: #{attr["version"]} (#{attr["buildNumber"]})"
    puts "  State: #{emoji} #{state}"
    puts "  Uploaded: #{uploaded}"
    puts
  end
  
  true
end

# Main
watch = ARGV.include?("--watch")
json_output = ARGV.include?("--json")

if watch
  puts "👀 Watching TestFlight builds (Ctrl+C to stop)..."
  puts
  loop do
    system("clear")
    check_builds(json_output: json_output)
    puts
    puts "Last checked: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    sleep 30
  end
else
  success = check_builds(json_output: json_output)
  exit(success ? 0 : 1)
end
