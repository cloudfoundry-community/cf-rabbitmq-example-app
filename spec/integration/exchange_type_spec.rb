require 'spec_helper'
require 'integration_helper'
require 'app'
require 'bunny'

# Amendment 2. Task 12 rescues both Bunny::ChannelLevelException and
# Bunny::ConnectionLevelException when declaring an x-consistent-hash
# exchange, reasoning from the AMQP 0-9-1 spec (reply-code 503,
# COMMAND_INVALID, is documented as a hard/connection-level error) rather
# than from an observed broker, because that reasoning could not be
# checked against a real one until this task.
#
# docker-compose.test.yml's rabbitmq-no-chx service is a broker with
# rabbitmq_consistent_hash_exchange deliberately NOT enabled - everything
# else the primary `rabbitmq` service has (mqtt, stomp, web-mqtt,
# web-stomp) is irrelevant to this question, so it stays off there too.
RSpec.describe 'declaring x-consistent-hash without the plugin, against a live broker', :integration do
  def app
    Sinatra::Application
  end

  # Bypasses the app entirely: this connects with plain Bunny, the same
  # way RabbitMQ::ConsistentHash#declare_exchange does, so what gets
  # raised here is exactly what that method has to rescue from - not a
  # stand-in for it.
  it 'raises a channel-level exception, not a connection-level one, and leaves the connection open' do
    connection = Bunny.new(
      host: RABBITMQ_HOST, port: 5673, tls: false, verify_peer: true,
      username: 'app-user', password: 'app-pass', vhost: '/'
    )
    connection.start
    channel = connection.create_channel

    raised = nil
    begin
      channel.exchange('itest-consistent-hash-probe', type: 'x-consistent-hash', durable: false)
    rescue StandardError => e
      raised = e
    end

    # Evidence for the report: exact class, its place in Bunny's
    # exception hierarchy, the wire-level reason, and whether the
    # connection itself survived.
    expect(raised).not_to be_nil, 'expected the broker to reject the unknown exchange type'
    expect(raised).to be_a(Bunny::ChannelLevelException)
    expect(raised).not_to be_a(Bunny::ConnectionLevelException)
    expect(raised.class).to eq(Bunny::PreconditionFailed)
    expect(raised.message).to match(/PRECONDITION_FAILED.*unknown exchange type/)

    expect(channel.closed?).to be(true)   # the channel is what actually closed...
    expect(connection.closed?).to be(false) # ...the connection did not

    connection.close
  end

  # The same declaration, driven through the real route, against a
  # binding that points at the plugin-missing broker - proving the app's
  # rescue clause (which still catches both exception families) actually
  # converts what the broker really sends into the documented 501, not
  # just that the exception class matches in isolation above.
  it 'the app converts the real broker rejection into 501 NOT-SUPPORTED' do
    ENV['VCAP_SERVICES'] = no_chx_vcap

    post '/demo/consistent-hash', queues: 2, messages: 1

    expect(last_response.status).to eq(501)
    expect(last_response.body).to include('rabbitmq_consistent_hash_exchange')
  end
end
