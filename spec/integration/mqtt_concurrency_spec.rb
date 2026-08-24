require 'spec_helper'
require 'integration_helper'
require 'app'

# Amendment 5: the MQTT concurrency strategies, against a live broker.
#
# MQTT consume is instance-affine (client_id keys off CF_INSTANCE_INDEX,
# defaulting to '0' locally) and, under the default 'serialized' strategy,
# additionally serialized by an in-process mutex (lib/rabbitmq/adapters/mqtt.rb).
# Rack::Test drives every request in this file sequentially on one thread,
# so the mutex is never actually contended here - it only matters once
# concurrent requests can reach the same process, which this suite
# doesn't attempt to simulate.
RSpec.describe 'MQTT concurrency strategies against a live broker', :integration do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = integration_vcap }

  # Previously skipped: declare and publish each reconnect under the same
  # client_id (serialized strategy), fired back-to-back with no gap, and
  # the broker used to lose the self-published message probabilistically
  # (0/15 recoveries with no gap). Root cause was ruby-mqtt's
  # Client#subscribe being fire-and-forget with no SUBACK wait at all -
  # #declare disconnected before the broker had necessarily finished
  # processing the SUBSCRIBE. Fixed in RabbitMQ::Adapters::MQTT#declare
  # by forcing a real round trip (a QoS-1 publish to a throwaway topic,
  # acknowledged via PUBACK) before disconnecting. Verified against a
  # real broker: 20/20 recoveries with zero gap, post-fix.
  it 'serialized supports subscribe (declare) then consume finding the same session' do
    name = itest_queue('mqtt-serialized')

    post '/mqtt/queues', name: name, mqtt: 'serialized'
    expect(last_response.status).to eq(201)

    put "/mqtt/queue/#{name}", data: 'hello-mqtt', mqtt: 'serialized'
    expect(last_response.status).to eq(201)

    get "/mqtt/queue/#{name}?mqtt=serialized"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("hello-mqtt\n")
  end

  it 'per-request returns 409, not an empty 204, since it cannot see a prior subscribe' do
    name = itest_queue('mqtt-per-request')

    # Subscribe under the strategy that actually persists a session...
    post '/mqtt/queues', name: name, mqtt: 'serialized'
    expect(last_response.status).to eq(201)
    put "/mqtt/queue/#{name}", data: 'hello-mqtt', mqtt: 'serialized'
    expect(last_response.status).to eq(201)

    # ...then consume under per-request, whose unique-per-request client_id
    # cannot see that session. The adapter refuses explicitly (409) rather
    # than connecting fresh and reporting an indistinguishable empty 204.
    get "/mqtt/queue/#{name}?mqtt=per-request"
    expect(last_response.status).to eq(409)
    expect(last_response.body).to include('STRATEGY-CONFLICT')
  end
end
