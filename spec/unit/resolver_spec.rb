require 'spec_helper'
require 'rabbitmq/binding'
require 'rabbitmq/resolver'

RSpec.describe RabbitMQ::Resolver do
  def resolver_for(fixture, env = {})
    binding = RabbitMQ::Binding.from_env({ 'VCAP_SERVICES' => vcap_fixture(fixture) })
    described_class.new(binding, env)
  end

  def resolver_with_credentials(credentials, env = {})
    vcap = JSON.generate('rabbitmq' => [{ 'label' => 'rabbitmq', 'credentials' => credentials }])
    binding = RabbitMQ::Binding.from_env({ 'VCAP_SERVICES' => vcap })
    described_class.new(binding, env)
  end

  describe 'advertised endpoints' do
    it 'uses the advertised amqp block verbatim' do
      endpoint = resolver_for('tls_off').resolve('amqp')
      expect(endpoint.host).to eq('10.7.16.17')
      expect(endpoint.port).to eq(5672)
      expect(endpoint.tls).to be(false)
      expect(endpoint.source).to eq(:advertised)
    end

    it 'marks the advertised amqps block as TLS' do
      endpoint = resolver_for('tls_on').resolve('amqps')
      expect(endpoint.port).to eq(5671)
      expect(endpoint.tls).to be(true)
      expect(endpoint.source).to eq(:advertised)
    end

    it 'resolves both amqp and amqps on a dual-mode binding' do
      resolver = resolver_for('dual_mode')
      expect(resolver.resolve('amqp').tls).to be(false)
      expect(resolver.resolve('amqps').tls).to be(true)
    end
  end

  describe 'derived endpoints' do
    it 'derives mqtt from the top-level host and the standard port' do
      endpoint = resolver_for('tls_off').resolve('mqtt')
      expect(endpoint.host).to eq('10.7.16.17')
      expect(endpoint.port).to eq(1883)
      expect(endpoint.tls).to be(false)
      expect(endpoint.source).to eq(:derived)
    end

    it 'derives stomp on its standard port' do
      expect(resolver_for('tls_off').resolve('stomp').port).to eq(61613)
    end

    it 'derives the TLS variant when the protocol name is a TLS protocol' do
      endpoint = resolver_for('tls_on').resolve('mqtts')
      expect(endpoint.port).to eq(8883)
      expect(endpoint.tls).to be(true)
    end

    it 'derives amqp from the uri scheme when protocols is absent' do
      endpoint = resolver_for('legacy_uri_only').resolve('amqp')
      expect(endpoint.port).to eq(5672)
      expect(endpoint.tls).to be(false)
      expect(endpoint.source).to eq(:derived)
    end

    it 'refuses to derive amqp when the uri is amqps, rather than mixing them' do
      resolver = resolver_for('tls_on')
      expect(resolver.resolve('amqp')).to be_nil
      expect(resolver.unavailable_reason('amqp'))
        .to match(/amqp is not advertised in the binding and could not be derived/)
    end

    it 'refuses to derive amqps when the uri is amqp, rather than mixing them' do
      resolver = resolver_for('tls_off')
      expect(resolver.resolve('amqps')).to be_nil
      expect(resolver.unavailable_reason('amqps'))
        .to match(/amqps is not advertised in the binding and could not be derived/)
    end
  end

  describe 'web_stomp_tls' do
    it 'is unavailable when not advertised, because it has no default port' do
      resolver = resolver_for('tls_on')
      expect(resolver.resolve('web_stomp_tls')).to be_nil
      expect(resolver.unavailable_reason('web_stomp_tls'))
        .to match(/no documented default port/)
    end
  end

  describe 'unbound' do
    it 'resolves nothing and says why' do
      resolver = described_class.new(RabbitMQ::Binding.from_env({}), {})
      expect(resolver.resolve('amqp')).to be_nil
      expect(resolver.unavailable_reason('amqp')).to match(/no RabbitMQ service bound/)
    end
  end

  describe 'verify_peer' do
    it 'defaults to true when TLS is on' do
      expect(resolver_for('tls_on').resolve('amqps').verify_peer?).to be(true)
    end

    it 'honours a strict false override' do
      endpoint = resolver_for('tls_on', { 'RABBITMQ_VERIFY_PEER' => 'false' }).resolve('amqps')
      expect(endpoint.verify_peer?).to be(false)
    end

    it 'honours a strict 0 override' do
      endpoint = resolver_for('tls_on', { 'RABBITMQ_VERIFY_PEER' => '0' }).resolve('amqps')
      expect(endpoint.verify_peer?).to be(false)
    end

    it 'raises on an unparseable override rather than guessing' do
      resolver = resolver_for('tls_on', { 'RABBITMQ_VERIFY_PEER' => 'yes-please' })
      expect { resolver.resolve('amqps') }.to raise_error(ArgumentError, /RABBITMQ_VERIFY_PEER/)
    end
  end

  describe 'mqtt vhost' do
    it 'prefixes the username with the vhost, which MQTT requires' do
      endpoint = resolver_for('tls_off').resolve('mqtt')
      expect(endpoint.username).to eq('0de041e6-91ba-4f55-b50f-d575ce91e2a5:app-user')
    end

    it 'does not prefix the username for amqp' do
      expect(resolver_for('tls_off').resolve('amqp').username).to eq('app-user')
    end
  end

  describe 'advertised block validation' do
    it 'falls through when the advertised block has no port and none can be derived' do
      resolver = resolver_with_credentials(
        'host' => '10.7.16.17',
        'username' => 'app-user',
        'password' => 'app-pass',
        'vhost' => '0de041e6-91ba-4f55-b50f-d575ce91e2a5',
        'protocols' => {
          'web_stomp_tls' => {
            'username' => 'app-user',
            'password' => 'app-pass',
            'host' => '10.7.16.17',
            'ssl' => true
          }
        }
      )

      expect(resolver.resolve('web_stomp_tls')).to be_nil
      expect(resolver.unavailable_reason('web_stomp_tls'))
        .to match(/no documented default port/)
    end

    it 'falls through when neither the block nor the top level has a host' do
      resolver = resolver_with_credentials(
        'username' => 'app-user',
        'password' => 'app-pass',
        'vhost' => '0de041e6-91ba-4f55-b50f-d575ce91e2a5',
        'protocols' => {
          'amqp' => {
            'username' => 'app-user',
            'password' => 'app-pass',
            'port' => 5672,
            'ssl' => false
          }
        }
      )

      expect(resolver.resolve('amqp')).to be_nil
      expect(resolver.unavailable_reason('amqp'))
        .to match(/amqp is not advertised in the binding and could not be derived/)
    end

    it 'coerces a string "ssl" flag to a real boolean rather than trusting it' do
      resolver = resolver_with_credentials(
        'host' => '10.7.16.17',
        'username' => 'app-user',
        'password' => 'app-pass',
        'vhost' => '0de041e6-91ba-4f55-b50f-d575ce91e2a5',
        'protocols' => {
          'amqp' => {
            'username' => 'app-user',
            'password' => 'app-pass',
            'host' => '10.7.16.17',
            'port' => 5672,
            'ssl' => 'false'
          }
        }
      )

      expect(resolver.resolve('amqp').tls).to be(false)
    end
  end

  describe 'endpoint serialization safety' do
    it 'never leaks the password through to_h, to_json, to_s, or inspect' do
      endpoint = resolver_for('tls_off').resolve('amqp')
      password = endpoint.password

      expect(endpoint.to_h.to_json).not_to include(password)
      expect(endpoint.to_json).not_to include(password)
      expect(JSON.generate(endpoint)).not_to include(password)
      expect(JSON.generate('e' => endpoint)).not_to include(password)
      expect(endpoint.to_s).not_to include(password)
      expect(endpoint.inspect).not_to include(password)
    end
  end
end
