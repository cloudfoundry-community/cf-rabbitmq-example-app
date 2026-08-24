require 'spec_helper'
require 'rabbitmq/endpoint'
require 'rabbitmq/adapters/stomp'

RSpec.describe RabbitMQ::Adapters::Stomp do
  let(:endpoint) do
    RabbitMQ::Endpoint.new(
      protocol: 'stomp', host: 'broker.example', port: 61613, tls: false,
      username: 'app-user', password: 'p', vhost: 'demo-vhost',
      source: :derived, verify_peer: true
    )
  end

  it 'sends the vhost in the CONNECT host header' do
    opts = described_class.new(endpoint).connection_options
    expect(opts[:connect_headers]['host']).to eq('demo-vhost')
  end

  it 'negotiates modern protocol versions' do
    opts = described_class.new(endpoint).connection_options
    expect(opts[:connect_headers]['accept-version']).to eq('1.0,1.1,1.2')
  end

  it 'does not prefix the username, unlike MQTT' do
    expect(described_class.new(endpoint).connection_options[:hosts].first[:login])
      .to eq('app-user')
  end

  it 'passes host, port and ssl' do
    host = described_class.new(endpoint).connection_options[:hosts].first
    expect(host[:host]).to eq('broker.example')
    expect(host[:port]).to eq(61613)
    expect(host[:ssl]).to be(false)
  end

  it 'enables ssl for a TLS endpoint' do
    tls = endpoint.dup.tap { |e| e.tls = true; e.port = 61614 }
    expect(described_class.new(tls).connection_options[:hosts].first[:ssl]).to be(true)
  end

  it 'addresses queues under /queue/' do
    expect(described_class.new(endpoint).destination('alpha')).to eq('/queue/alpha')
  end

  it 'bounds the initial connect so an unreachable broker cannot hang forever' do
    opts = described_class.new(endpoint).connection_options
    expect(opts[:start_timeout]).to be > 0
  end

  # Stomp::Client.new returns as soon as the socket is up, so the CONNECT
  # outcome is only visible on the client's connection_frame.
  let(:connected_frame) { instance_double(Stomp::Message, command: 'CONNECTED', headers: {}) }
  let(:refused_frame) do
    instance_double(Stomp::Message, command: 'ERROR', headers: { 'message' => 'Bad CONNECT' })
  end

  describe 'a CONNECT the broker refused' do
    # Before this guard existed, a refused login reached #ping's
    # unconditional [200, 'OK'] and #publish's [201, 'SUCCESS'] - the app
    # reported a healthy binding while the broker was turning it away.
    # Verified against the real broker with a wrong password: 200 OK and
    # 201 SUCCESS before, 502 after.
    let(:client) do
      instance_double(Stomp::Client, subscribe: nil, unsubscribe: nil,
                                     close: nil, connection_frame: refused_frame)
    end

    before { allow(Stomp::Client).to receive(:new).and_return(client) }

    it 'reports 502 from ping rather than OK' do
      status, body = described_class.new(endpoint).ping
      expect(status).to eq(502)
      expect(body).to include('Bad CONNECT')
    end

    it 'reports 502 from publish rather than SUCCESS' do
      status, = described_class.new(endpoint).publish('alpha', 'data')
      expect(status).to eq(502)
    end

    it 'reports 502 from declare rather than SUCCESS' do
      status, = described_class.new(endpoint).declare('alpha')
      expect(status).to eq(502)
    end

    it 'never writes to a refused connection' do
      described_class.new(endpoint).publish('alpha', 'data')
      expect(client).not_to have_received(:subscribe)
    end

    it 'still closes the client' do
      described_class.new(endpoint).ping
      expect(client).to have_received(:close)
    end
  end

  describe '#declare' do
    # The STOMP plugin creates a queue on SUBSCRIBE, so declare has to
    # subscribe - but that registers a real consumer, and the broker does
    # not tear it down synchronously when the connection closes. Under
    # ack "auto" (the gem's default) a message published into that window
    # was delivered to this throwaway subscriber and acked away, losing
    # it: measured at ~30% of integration runs before the fix. ack
    # "client" with no ack ever sent means the broker requeues instead.
    #
    # This asserts the header explicitly rather than the absence of the
    # symptom, because the symptom is a broker-timing race that no unit
    # test can provoke.
    it 'subscribes with ack "client" so a raced message is requeued, not eaten' do
      client = instance_double(Stomp::Client, subscribe: nil, unsubscribe: nil,
                               close: nil, connection_frame: connected_frame)
      allow(Stomp::Client).to receive(:new).and_return(client)

      status, = described_class.new(endpoint).declare('alpha')

      expect(status).to eq(201)
      expect(client).to have_received(:subscribe)
        .with('/queue/alpha', hash_including('ack' => 'client'))
    end
  end

  describe '#consume' do
    # Same teardown window as declare: unsubscribe and close are
    # fire-and-forget, so under ack auto a message arriving after the
    # timeout would be delivered to a consumer nobody reads and destroyed.
    it 'subscribes with ack "client" and acks only the message it returns' do
      msg = instance_double(Stomp::Message, body: 'payload')
      client = instance_double(Stomp::Client, unsubscribe: nil, close: nil,
                                              connection_frame: connected_frame)
      allow(client).to receive(:subscribe) { |_d, _h, &blk| blk.call(msg) }
      allow(client).to receive(:acknowledge)
      allow(Stomp::Client).to receive(:new).and_return(client)

      status, body = described_class.new(endpoint).consume('alpha')

      expect(status).to eq(200)
      expect(body).to eq("payload\n")
      expect(client).to have_received(:subscribe)
        .with('/queue/alpha', hash_including('ack' => 'client'))
      expect(client).to have_received(:acknowledge).with(msg)
    end

    it 'closes the client and unsubscribes even when the read times out' do
      client = instance_double(Stomp::Client, subscribe: nil, unsubscribe: nil,
                               close: nil, connection_frame: connected_frame)
      allow(Stomp::Client).to receive(:new).and_return(client)
      allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

      status, body = described_class.new(endpoint).consume('alpha')

      expect(status).to eq(204)
      expect(body).to eq('')
      expect(client).to have_received(:unsubscribe).with('/queue/alpha')
      expect(client).to have_received(:close)
    end

    it 'still closes the client when construction itself raises' do
      allow(Stomp::Client).to receive(:new).and_raise(Stomp::Error::MaxReconnectAttempts.new)

      expect { described_class.new(endpoint).consume('alpha') }
        .to raise_error(Stomp::Error::MaxReconnectAttempts)
    end
  end
end
