require 'spec_helper'
require 'app'

RSpec.describe 'browser demo routes' do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = vcap_fixture('tls_off') }

  it 'serves the web-mqtt demo page' do
    get '/web-mqtt/demo'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('mqtt.min.js')
  end

  it 'serves the web-stomp demo page' do
    get '/web-stomp/demo'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('stomp.umd.min.js')
  end

  # The pages above only prove the script *tag* names the right file - not
  # that the file is actually reachable at that URL. Sinatra's automatic
  # static-file serving is driven by settings.public_folder, which is not
  # the repo-root public/ this task vendors into (see report); fetching
  # the scripts the pages reference is the only way to catch that a
  # string match on the tag text would miss.
  it 'serves the vendored mqtt.js bundle the mqtt page references' do
    get '/js/mqtt.min.js'
    expect(last_response.status).to eq(200)
  end

  it 'serves the vendored stomp.js bundle the stomp page references' do
    get '/js/stomp.umd.min.js'
    expect(last_response.status).to eq(200)
  end

  it 'exposes endpoint config without the password' do
    get '/demo/config.json'
    expect(last_response.status).to eq(200)
    config = JSON.parse(last_response.body)
    expect(config['web_mqtt']['port']).to eq(15675)
    expect(last_response.body).not_to include('app-pass')
  end

  it 'never carries the password on either rendered demo page' do
    get '/web-mqtt/demo'
    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('app-pass')

    get '/web-stomp/demo'
    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include('app-pass')
  end

  it 'renders both demo pages fully offline, with no external asset references' do
    get '/web-mqtt/demo'
    expect(last_response.status).to eq(200)
    expect(strip_html_comments(last_response.body)).not_to match(%r{https?://})

    get '/web-stomp/demo'
    expect(last_response.status).to eq(200)
    expect(strip_html_comments(last_response.body)).not_to match(%r{https?://})
  end

  # The /demo/config.json route (lib/routes/demo.rb) builds its report by
  # calling resolver.resolve for each of the four web_* keys and skipping
  # any that come back nil - it never requires at least one to resolve.
  # When the binding advertises none of them and none can be derived, the
  # endpoint is nil for every one, and the route must still answer 200
  # with an empty report rather than raising.
  it 'returns an empty report, not an error, when no web_* protocol resolves' do
    allow_any_instance_of(RabbitMQ::Resolver).to receive(:resolve).and_return(nil)

    get '/demo/config.json'

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq({})
  end

  def strip_html_comments(html)
    html.gsub(/<!--.*?-->/m, '')
  end
end
