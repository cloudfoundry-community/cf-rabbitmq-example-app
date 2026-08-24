require 'spec_helper'
require 'integration_helper'
require 'app'

# TLS against real brokers (docker-compose.test.yml: rabbitmq-tls and
# rabbitmq-wrong-host). Three things are being held down here, and only
# the first is about messages moving:
#
#   1. every protocol still round-trips when the certificate is good
#   2. a certificate from an untrusted CA is refused
#   3. a certificate from a TRUSTED CA that names a different host is
#      refused too
#
# (2) and (3) are the ones with history. Before RabbitMQ::TLS existed,
# /mqtts/ping, /stomps/ping, /web-mqtt-tls/ping and /web-stomp-tls/ping
# all answered 200 OK against a broker whose CA was in no trust store -
# encryption with no authentication, reported as a healthy binding. Three
# of those four also passed (3). The client gems default that way:
# ruby-mqtt sets no verify_mode, stomp hard-codes VERIFY_NONE, and
# websocket-client-simple only verifies if the caller asks.
RSpec.describe 'TLS against live brokers', :integration do
  def app
    Sinatra::Application
  end

  # SSL_CERT_FILE is read by OpenSSL every time a store calls
  # set_default_paths, so flipping it between examples genuinely changes
  # what Bunny, Net::HTTP, ruby-mqtt and RabbitMQ::TLS trust - no process
  # restart involved.
  around do |example|
    previous = ENV['SSL_CERT_FILE']
    example.run
  ensure
    ENV['SSL_CERT_FILE'] = previous
  end

  def trust_the_test_ca
    ENV['SSL_CERT_FILE'] = tls_trust_bundle
  end

  def trust_only_the_platform
    ENV['SSL_CERT_FILE'] = OpenSSL::X509::DEFAULT_CERT_FILE
  end

  TLS_PROTOCOLS = %w[amqps management-tls mqtts stomps web-mqtt-tls web-stomp-tls].freeze

  describe 'a certificate that verifies' do
    before do
      trust_the_test_ca
      ENV['VCAP_SERVICES'] = tls_vcap
    end

    TLS_PROTOCOLS.each do |protocol|
      it "answers /#{protocol}/ping" do
        get "/#{protocol}/ping"
        expect(last_response.status).to eq(200), last_response.body
      end
    end

    # amqps is advertised; stomps and mqtts are derived from their
    # standard TLS ports. Covering one of each proves the derived path
    # carries TLS-ness correctly, not just the advertised one.
    %w[amqps stomps mqtts].each do |protocol|
      it "round-trips a message over #{protocol}" do
        name = itest_queue(protocol)

        post "/#{protocol}/queues", name: name
        expect(last_response.status).to eq(201), last_response.body

        put "/#{protocol}/queue/#{name}", data: "hello-#{protocol}"
        expect(last_response.status).to eq(201), last_response.body

        get "/#{protocol}/queue/#{name}"
        expect(last_response.status).to eq(200), last_response.body
        expect(last_response.body).to eq("hello-#{protocol}\n")
      end
    end

    it 'reports the TLS endpoints as tls: true on /protocols' do
      get '/protocols'
      report = JSON.parse(last_response.body)

      expect(report['amqps']).to include('tls' => true, 'source' => 'advertised')
      expect(report['mqtts']).to include('tls' => true, 'source' => 'derived', 'port' => 8883)
    end
  end

  describe 'a certificate from a CA in no trust store' do
    before do
      trust_only_the_platform
      ENV['VCAP_SERVICES'] = tls_vcap
    end

    TLS_PROTOCOLS.each do |protocol|
      it "refuses /#{protocol}/ping rather than reporting a healthy binding" do
        get "/#{protocol}/ping"

        expect(last_response.status).not_to eq(200)
        expect(last_response.body).to match(/certificate|SSL|TLS/i)
      end
    end
  end

  describe 'a certificate from a trusted CA that names a different host' do
    before do
      trust_the_test_ca
      ENV['VCAP_SERVICES'] = wrong_host_vcap
    end

    TLS_PROTOCOLS.each do |protocol|
      it "refuses /#{protocol}/ping" do
        get "/#{protocol}/ping"

        expect(last_response.status).not_to eq(200)
        expect(last_response.body).to match(/hostname|certificate/i)
      end
    end
  end

  # The escape hatch has to work for every protocol, or an operator whose
  # broker uses a private CA is stuck with a half-working app. This is the
  # documented way to run against a Blacksmith instance without adding its
  # CA to the container's trust store.
  describe 'RABBITMQ_VERIFY_PEER=false' do
    around do |example|
      previous = ENV['RABBITMQ_VERIFY_PEER']
      ENV['RABBITMQ_VERIFY_PEER'] = 'false'
      example.run
    ensure
      ENV['RABBITMQ_VERIFY_PEER'] = previous
    end

    before do
      trust_only_the_platform
      ENV['VCAP_SERVICES'] = tls_vcap
    end

    TLS_PROTOCOLS.each do |protocol|
      it "connects over #{protocol} despite the untrusted CA" do
        get "/#{protocol}/ping"
        expect(last_response.status).to eq(200), last_response.body
      end
    end
  end
end
