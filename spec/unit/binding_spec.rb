require 'spec_helper'
require 'rabbitmq/binding'

RSpec.describe RabbitMQ::Binding do
  describe '.from_env' do
    it 'is unbound when VCAP_SERVICES is absent' do
      expect(described_class.from_env({}).bound?).to be(false)
    end

    it 'is unbound when VCAP_SERVICES is empty' do
      expect(described_class.from_env({ 'VCAP_SERVICES' => '' }).bound?).to be(false)
    end

    it 'is unbound when no service looks like rabbitmq' do
      env = { 'VCAP_SERVICES' => '{"redis":[{"credentials":{"host":"h"}}]}' }
      expect(described_class.from_env(env).bound?).to be(false)
    end

    it 'finds credentials regardless of the service label' do
      env = { 'VCAP_SERVICES' => vcap_fixture('tls_off') }
      binding = described_class.from_env(env)
      expect(binding.bound?).to be(true)
      expect(binding.credentials['username']).to eq('app-user')
      expect(binding.credentials['vhost']).to eq('0de041e6-91ba-4f55-b50f-d575ce91e2a5')
    end
  end

  describe '#protocol' do
    it 'returns an advertised protocol block' do
      binding = described_class.from_env({ 'VCAP_SERVICES' => vcap_fixture('tls_off') })
      expect(binding.protocol('amqp')['port']).to eq(5672)
    end

    it 'returns nil for a protocol that is not advertised' do
      binding = described_class.from_env({ 'VCAP_SERVICES' => vcap_fixture('tls_off') })
      expect(binding.protocol('mqtt')).to be_nil
    end

    it 'returns nil when the binding has no protocols key' do
      binding = described_class.from_env({ 'VCAP_SERVICES' => vcap_fixture('legacy_uri_only') })
      expect(binding.protocols).to eq({})
      expect(binding.protocol('amqp')).to be_nil
    end
  end
end
