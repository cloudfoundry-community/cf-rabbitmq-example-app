require 'spec_helper'
require 'socket'
require 'timeout'
require 'securerandom'

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

    [[RABBITMQ_HOST, 5672], [RABBITMQ_HOST, 5673]].each do |host, port|
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
              'Start the brokers first: docker compose -f docker-compose.test.yml up -d --wait'
      end
    end
  end
end
