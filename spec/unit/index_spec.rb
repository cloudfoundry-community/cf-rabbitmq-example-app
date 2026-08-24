require 'spec_helper'
require 'app'

RSpec.describe 'root index' do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = vcap_fixture('tls_off') }

  it 'lists every protocol with its availability' do
    get '/'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('amqp')
    expect(last_response.body).to include('mqtt')
    expect(last_response.body).to include('web_stomp_tls')
  end

  it 'distinguishes advertised from derived from unavailable' do
    get '/'
    expect(last_response.body).to match(/advertised/)
    expect(last_response.body).to match(/derived/)
    expect(last_response.body).to match(/unavailable/)
  end

  it 'shows amqp as selected by default' do
    get '/'
    expect(last_response.body).to match(/selected/i)
  end

  it 'never renders the password' do
    get '/'
    # Pinned: without it a 500 body ("ERR:...") contains no 'app-pass'
    # either, so a broken route would satisfy the assertion.
    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('app-pass')
  end

  it 'sets the selection cookie and redirects' do
    post '/select', protocol: 'stomp'
    expect(last_response.status).to eq(302)
    expect(last_response.headers['Set-Cookie']).to include('rmq_protocol=stomp')
  end

  it 'refuses an unknown protocol rather than storing it' do
    post '/select', protocol: 'nonsense'
    expect(last_response.status).to eq(400)
    expect(last_response.headers['Set-Cookie'].to_s).not_to include('nonsense')
  end

  it 'does not offer a protocol that resolves but has no registered adapter' do
    # Every protocol in Resolver::PROTOCOLS now has a registered adapter,
    # so the gate (`available && adapter` in views/index.erb) is exercised
    # here via a stub rather than a real gap in the registry. protocol_report
    # calls adapter_for for every protocol, so a with()-constrained stub
    # with no default raises on the others - and that MockExpectationError
    # (a bare Exception, not StandardError) gets routed to the app's own
    # catch-all 500 by Sinatra's dispatch!, which the "not_to match" below
    # would pass against just as happily as a real, correctly-gated page.
    # Assert the 200 explicitly so an error page can never pass silently,
    # and pair the negative with positives so a filter that excluded
    # everything can't pass vacuously either.
    allow(RabbitMQ::Registry).to receive(:adapter_for).and_call_original
    allow(RabbitMQ::Registry).to receive(:adapter_for).with('mqtt').and_return(nil)
    get '/'
    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to match(/name="protocol"[^>]*value="mqtt"/)
    expect(last_response.body).to match(/name="protocol"[^>]*value="stomp"/)
    expect(last_response.body).to match(/name="protocol"[^>]*value="amqp"/)
  end

  it 'offers mqtt, stomp and web_mqtt now that they resolve and have a registered adapter' do
    get '/'
    expect(last_response.body).to match(/name="protocol"[^>]*value="mqtt"/)
    expect(last_response.body).to match(/name="protocol"[^>]*value="stomp"/)
    expect(last_response.body).to match(/name="protocol"[^>]*value="web_mqtt"/)
  end

  it 'does offer protocols that resolve and have an adapter' do
    get '/'
    expect(last_response.body).to match(/name="protocol"[^>]*value="amqp"/)
  end

  context 'when no service is bound' do
    before { ENV.delete('VCAP_SERVICES') }

    it 'renders the binding instructions instead of a protocol list' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/bind a RabbitMQ service instance/)
    end
  end
end
