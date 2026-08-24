require 'spec_helper'
require 'rabbitmq/endpoint'
require 'rabbitmq/tls'

RSpec.describe RabbitMQ::TLS do
  def endpoint(tls:, verify_peer:)
    RabbitMQ::Endpoint.new(
      protocol: 'mqtts', host: 'broker.example', port: 8883, tls: tls,
      username: 'u', password: 'p', vhost: 'v', source: :derived,
      verify_peer: verify_peer
    )
  end

  describe '.verify_mode' do
    it 'verifies a TLS endpoint the operator asked to verify' do
      expect(described_class.verify_mode(endpoint(tls: true, verify_peer: true)))
        .to eq(OpenSSL::SSL::VERIFY_PEER)
    end

    it 'skips verification when the operator opted out' do
      expect(described_class.verify_mode(endpoint(tls: true, verify_peer: false)))
        .to eq(OpenSSL::SSL::VERIFY_NONE)
    end

    # verify_peer? is already false for a plaintext endpoint, so this is
    # only a guard against a caller reading the raw member instead.
    it 'skips verification for a plaintext endpoint' do
      expect(described_class.verify_mode(endpoint(tls: false, verify_peer: true)))
        .to eq(OpenSSL::SSL::VERIFY_NONE)
    end
  end

  describe '.cert_store' do
    # set_default_paths is what makes SSL_CERT_FILE / SSL_CERT_DIR work,
    # which is how an operator trusts a private CA (every Blacksmith
    # deployment issues its own) without this app inventing a binding
    # field for it.
    it 'returns a store seeded from OpenSSL default paths' do
      store = instance_double(OpenSSL::X509::Store)
      allow(OpenSSL::X509::Store).to receive(:new).and_return(store)
      expect(store).to receive(:set_default_paths)

      expect(described_class.cert_store).to be(store)
    end

    it 'hands back a fresh store each call, never a shared mutable one' do
      expect(described_class.cert_store).not_to be(described_class.cert_store)
    end
  end
end
