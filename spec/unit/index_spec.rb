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

  it 'does not offer protocols that have no registered adapter' do
    get '/'
    expect(last_response.body).not_to match(/name="protocol"[^>]*value="mqtt"/)
    expect(last_response.body).not_to match(/name="protocol"[^>]*value="stomp"/)
    expect(last_response.body).not_to match(/name="protocol"[^>]*value="web_mqtt"/)
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
