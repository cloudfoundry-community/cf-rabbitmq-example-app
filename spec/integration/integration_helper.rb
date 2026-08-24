require 'spec_helper'
require 'socket'
require 'timeout'
require 'securerandom'
require 'openssl'

# Queues declared with durable: false survive as long as the broker
# process keeps running, so a fixed queue name would hit the app's own
# 304 EXISTS on a second local run against a broker left up from the
# first. A per-run suffix keeps every run's queues fresh without the
# suite having to clean up after itself.
RUN_ID = SecureRandom.hex(4).freeze

def itest_queue(label)
  "itest-#{label}-#{RUN_ID}"
end

# spec/integration talks to real brokers started by docker-compose.test.yml
# (see that file for exactly what is enabled where). Nothing in this file
# stubs the network.

RABBITMQ_HOST = ENV.fetch('RABBITMQ_HOST', '127.0.0.1').freeze

# The MQTT plugin takes no vhost from the connection - the username
# carries the vhost prefix instead (see RabbitMQ::Resolver::VHOST_PREFIXED).
# This fixture advertises only amqp and management, which is what a real
# Blacksmith binding does - everything else here (mqtt, stomp, web_mqtt,
# web_stomp, ...) is exercised through the app's *derived* path, on the
# broker's standard ports, against the top-level host. That asymmetry is
# the point: see /protocols in protocols_spec.rb.
def integration_vcap
  {
    'rabbitmq' => [{
      'label' => 'rabbitmq',
      'name' => 'integration',
      'credentials' => {
        'host' => RABBITMQ_HOST,
        'username' => 'app-user',
        'password' => 'app-pass',
        'vhost' => 'demo-vhost',
        'uri' => "amqp://app-user:app-pass@#{RABBITMQ_HOST}:5672",
        'protocols' => {
          'amqp' => {
            'host' => RABBITMQ_HOST,
            'port' => 5672, 'ssl' => false,
            'username' => 'app-user', 'password' => 'app-pass',
            'vhost' => 'demo-vhost'
          },
          'management' => {
            'host' => RABBITMQ_HOST,
            'port' => 15672, 'ssl' => false, 'path' => '/api',
            'username' => 'app-user', 'password' => 'app-pass'
          }
        }
      }
    }]
  }.to_json
end

# Points at rabbitmq-no-chx (docker-compose.test.yml), which has no
# rabbitmq_consistent_hash_exchange plugin - see exchange_type_spec.rb /
# amendment 2. Deliberately its own binding rather than a second protocol
# on integration_vcap's broker, so the plugin-missing broker never
# interferes with anything else in the suite.
#
# 'amqp' has to be advertised, not left to derive: RabbitMQ::Resolver's
# derived path always uses the protocol's *standard* port (5672), never a
# port parsed out of a bare 'uri' - so a derived-only fixture here would
# silently reconnect to the OTHER (plugin-enabled) broker on 5672 instead
# of this one on 5673, which is exactly what happened the first time this
# fixture was written.
def no_chx_vcap
  {
    'rabbitmq' => [{
      'label' => 'rabbitmq',
      'name' => 'integration-no-chx',
      'credentials' => {
        'host' => RABBITMQ_HOST,
        'username' => 'app-user',
        'password' => 'app-pass',
        'vhost' => '/',
        'uri' => "amqp://app-user:app-pass@#{RABBITMQ_HOST}:5673",
        'protocols' => {
          'amqp' => {
            'host' => RABBITMQ_HOST,
            'port' => 5673, 'ssl' => false,
            'username' => 'app-user', 'password' => 'app-pass',
            'vhost' => '/'
          }
        }
      }
    }]
  }.to_json
end

TLS_CERT_DIR = File.expand_path('../support/tls', __dir__).freeze

# The trust store the app is pointed at for the "certificate verifies"
# cases: the platform's own CAs plus this suite's throwaway CA. Built at
# run time rather than by gen-tls-certs.sh, because the platform bundle's
# location is a property of the Ruby doing the running.
#
# SSL_CERT_FILE is the whole mechanism here - it is what
# OpenSSL::X509::Store#set_default_paths reads, so it steers Bunny,
# Net::HTTP, ruby-mqtt and RabbitMQ::TLS alike. It is also exactly how an
# operator trusts a private CA on Cloud Foundry, which is what a
# Blacksmith deployment always has.
def tls_trust_bundle
  path = File.join(TLS_CERT_DIR, 'bundle.pem')
  return path if File.exist?(path)

  default = OpenSSL::X509::DEFAULT_CERT_FILE
  platform = File.exist?(default) ? File.read(default) : ''
  File.write(path, platform + File.read(File.join(TLS_CERT_DIR, 'ca.crt')))
  path
end

# A broker on the standard TLS ports (docker-compose.test.yml:
# rabbitmq-tls), holding a certificate for localhost from this suite's CA.
#
# Advertises amqps, management_tls and web_stomp_tls; mqtts, stomps and
# web_mqtt_tls are left to derive, so the derived path is covered over TLS
# too. web_stomp_tls has to be advertised - RabbitMQ documents no default
# TLS port for web-stomp, so the app has none to derive from.
def tls_vcap(host: RABBITMQ_HOST)
  {
    'rabbitmq' => [{
      'label' => 'rabbitmq', 'name' => 'integration-tls',
      'credentials' => {
        'host' => host, 'username' => 'app-user', 'password' => 'app-pass',
        'vhost' => 'demo-vhost',
        'uri' => "amqps://app-user:app-pass@#{host}:5671",
        'protocols' => {
          'amqps' => {
            'host' => host, 'port' => 5671, 'ssl' => true,
            'username' => 'app-user', 'password' => 'app-pass', 'vhost' => 'demo-vhost'
          },
          'management_tls' => {
            'host' => host, 'port' => 15_671, 'ssl' => true, 'path' => '/api',
            'username' => 'app-user', 'password' => 'app-pass'
          },
          'web_stomp_tls' => {
            'host' => host, 'port' => 15_679, 'ssl' => true,
            'username' => 'app-user', 'password' => 'app-pass', 'vhost' => 'demo-vhost'
          }
        }
      }
    }]
  }.to_json
end

# docker-compose.test.yml: rabbitmq-wrong-host. Same CA as tls_vcap's
# broker, but the certificate names wrong.example.invalid, so every
# endpoint here should be refused on identity alone. Every protocol is
# advertised because none of these ports is a standard one.
def wrong_host_vcap(host: RABBITMQ_HOST)
  ports = {
    'amqps' => 5681, 'management_tls' => 26_671, 'mqtts' => 18_883,
    'stomps' => 51_614, 'web_mqtt_tls' => 25_676, 'web_stomp_tls' => 25_679
  }
  protocols = ports.each_with_object({}) do |(name, port), acc|
    acc[name] = {
      'host' => host, 'port' => port, 'ssl' => true,
      'username' => 'app-user', 'password' => 'app-pass', 'vhost' => 'demo-vhost'
    }
    acc[name]['path'] = '/api' if name == 'management_tls'
  end

  {
    'rabbitmq' => [{
      'label' => 'rabbitmq', 'name' => 'integration-wrong-host',
      'credentials' => {
        'host' => host, 'username' => 'app-user', 'password' => 'app-pass',
        'vhost' => 'demo-vhost',
        'uri' => "amqps://app-user:app-pass@#{host}:5681",
        'protocols' => protocols
      }
    }]
  }.to_json
end

# Polls instead of sleeping a fixed duration - a broker (or, for
# queue-depth assertions, the management plugin's stats collector, which
# updates on its own interval rather than synchronously with a publish)
# becomes ready on its own schedule. Failing after a bounded timeout with
# the last-seen value beats both a flaky fixed sleep and a hang.
def wait_until(timeout: 10, interval: 0.2, message: 'condition')
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    result = yield
    return result if result

    raise "timed out after #{timeout}s waiting for #{message}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep interval
  end
end

# Suite-level readiness gate: fails fast, with a clear message, instead of
# letting the first example time out mysteriously if the broker(s) are not
# up yet. docker-compose's own healthcheck already gates `docker compose up
# -d --wait`; this is a second, RSpec-side check for anyone who runs the
# integration suite without having waited on that themselves.
RSpec.configure do |config|
  # spec_helper.rb loads webmock/rspec, which blocks all real network
  # connections by default - the right default for spec/unit, where a
  # real connection slipping through a stub is itself a bug. Integration
  # examples are the one place that has to reach the real broker; scoped
  # to :integration metadata rather than lifted globally, so RABBITMQ_INTEGRATION=1
  # never weakens spec/unit's own protection if the two ever ran together.
  config.before(:each, :integration) { WebMock.allow_net_connect! }
  config.after(:each, :integration) { WebMock.disable_net_connect! }

  config.before(:suite) do
    next unless ENV['RABBITMQ_INTEGRATION'] == '1'

    [[RABBITMQ_HOST, 5672], [RABBITMQ_HOST, 5673],
     [RABBITMQ_HOST, 5671], [RABBITMQ_HOST, 5681]].each do |host, port|
      begin
        Timeout.timeout(15) do
          loop do
            begin
              TCPSocket.new(host, port).close
              break
            rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
              sleep 0.3
            end
          end
        end
      rescue Timeout::Error
        raise "spec/integration: #{host}:#{port} never accepted a connection. " \
              'Start the brokers first: spec/support/gen-tls-certs.sh && ' \
              'docker compose -f docker-compose.test.yml up -d --wait'
      end
    end
  end
end
