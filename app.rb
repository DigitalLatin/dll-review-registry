require 'rubygems'
require 'sinatra'
require 'securerandom'
require 'mongo'
require 'json/ext' # required for .to_json
require "digest"
require 'uri'
require 'httparty'
require 'gon-sinatra'
require 'octokit'

CLIENT_ID = ENV['CLIENT_ID']
CLIENT_SECRET = ENV['CLIENT_SECRET']

use Rack::Session::Pool
Sinatra::register Gon::Sinatra

configure do
  if settings.development?
    dbname = "test"
    db = Mongo::Client.new(['127.0.0.1:27017'], :database => dbname)
  elsif settings.environment == :docker
    dbname = "test"
    db = Mongo::Client.new(['mongodb:27017'], :database => dbname)
  else
    dbname = ENV['MONGODB_URI'].split("/").last
    db = Mongo::Client.new(ENV['MONGODB_URI'], :database => dbname)
  end
  set :mongo_db, db[dbname.to_sym]
  set :server, :puma
  set :bind, "0.0.0.0"
  set :protection, except: [:frame_options, :json_csrf]
  set :root, File.dirname(__FILE__)
  set :public_folder, 'public'

  # this added in attempt to "forbidden" response when clicking on links
  #set :protection, :except => :ip_spoofing
  #set :protection, :except => :json
end

if settings.development?
  require 'pry'
end

# authentation code taken from https://developer.github.com/v3/guides/basics-of-authentication/ and http://radek.io/2014/08/03/github-oauth-with-octokit/
def authenticated?
  session[:access_token]
end

def authenticate!
  client = Octokit::Client.new
  scopes = ['user']
  url = client.authorize_url(CLIENT_ID, :scope => 'repo')

  redirect url
end
def authorized?
  begin
    client = Octokit::Client.new :access_token => session[:access_token]
    data = client.user
    username = data.login
  rescue
    username = ""
  end
  username == "jeffreycwitt"
end


get '/login' do
  if !authenticated?
    authenticate!
  else
    access_token = session[:access_token]
    scopes = []

    client = Octokit::Client.new \
      :client_id => CLIENT_ID,
      :client_secret => CLIENT_SECRET

    begin
      client.check_application_authorization access_token
    rescue => e
      # request didn't succeed because the token was revoked so we
      # invalidate the token stored in the session and render the
      # index page so that the user can start the OAuth flow again

      session[:access_token] = nil
      return authenticate!
    end

    # doesn't necessarily need to go in 'editor'
    redirect '/'
  end
end
get '/logout' do
  session.clear
  redirect '/'
end
get '/return' do
  # get code return from github and get access token
  session_code = request.env['rack.request.query_hash']['code']
  result = Octokit.exchange_code_for_token(session_code, CLIENT_ID, CLIENT_SECRET)
  session[:access_token] = result[:access_token]

  redirect '/'
end

get '/' do
  begin
    client = Octokit::Client.new :access_token => session[:access_token]
    data = client.user
    @username = data.login
    @user_url = data.html_url
    gon.access_token = session[:access_token]
    gon.username = @username
  rescue
  end

  erb :index
end

get '/rubric/:society' do |society|
  if society == "maa"
    erb :maa_rubric
  end
end
get '/reviews' do
  @reviews = []
  @authorized = authorized?
  db = settings.mongo_db
  db.find().map {|object|
    @reviews << object
  }
  erb :reviews
end
get '/about' do
  erb :about
end
get '/docs' do
  redirect 'docs/index.html'
end
# find a document by its Mongo ID
get '/document/:id/?' do
  content_type :json
  document_by_id(params[:id])
end

get '/reviews/create' do
  if authorized?
    erb :create
  else
    "not authorized"
  end
end

post '/reviews/create' do
  if authorized?
    if params[:review_text_url].include? "master"
      @message = "sorry, it looks like you've used a github branch url, please is a url with the file blob hash"
      @success = false
      erb :create_completed
    else
      id = SecureRandom.uuid
      date = Time.new
      review_text_url = params[:review_text_url]
      review_society = params[:review_society]
      review_summary = params[:review_summary]
      review_badge_number = params[:review_badge_number]
      if review_badge_number == "1"
        review_badge = "#{request.base_url}/maa-badge-working.svg"
        badge_rubric = "#{request.base_url}/rubric/maa#green"
      elsif review_badge_number == "2"
        review_badge = "#{request.base_url}/maa-badge.svg"
        badge_rubric = "#{request.base_url}/rubric/maa#gold"
      end

      response = HTTParty.get(review_text_url)
      shasum = Digest::SHA2.hexdigest(response.body)


      filename = review_text_url.split('/').last
      File.open("tmp/#{filename}", 'w') { |file|
        file.write(response.body)
      }
      puts "IPFS test"
      ipfs_report = `ipfs add "tmp/#{filename}"`
      puts ipfs_report
      ipfs_hash = ipfs_report.split(" ")[1]


      review_content =  {
          "id": id,
          "review-society": review_society,
          "date": date,
          "badge-url": review_badge,
          "badge-rubric": badge_rubric,
          "review-report": nil,
          "review-summary": review_summary,
          "sha-256": shasum,
          "ipfs-hash": ipfs_hash,
          "submitted-url": review_text_url
      }
      #filename = "public/" + id + '.json'
      #final_content = JSON.pretty_generate(review_content)
      db = settings.mongo_db
      db.insert_one(review_content)
      #File.open(filename, 'w') { |file|
      #  file.write(final_content)
      #}
      @id = id
      @success = true
      @message = "Congratulations, Review Created"
      erb :create_completed
    end
  else
    "not authorized"
  end

end

get '/reviews/:id.json' do |id|
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json
  db = settings.mongo_db
  document = db.find( { "id": "#{id}" } ).to_a.first
  (document || {}).to_json

end
get '/reviews/:id.html' do |id|
  db = settings.mongo_db
  @document = db.find( { "id": "#{id}" } ).to_a.first
  @id = @document["id"]
  erb :show
end

get '/reviews/:id/delete' do |id|
  if authorized?
    db = settings.mongo_db
    db.delete_one( { "id": "#{id}" } )
    redirect "/reviews"
  else
    "not authorized"
  end
end

get '/hash/:hash.json' do |id|
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json
  db = settings.mongo_db
  if id.start_with? "Qm"
    documents = db.find( { "ipfs-hash": "#{id}"}).to_a
  else
    documents = db.find( { "sha-256": "#{id}"}).to_a
  end
  (documents || {}).to_json
end
get '/hash/:hash.html' do |id|
  db = settings.mongo_db
  if id.start_with? "Qm"
    @documents = db.find( { "ipfs-hash": "#{id}"}).to_a
  else
    @documents = db.find( { "sha-256": "#{id}"}).to_a
  end
  erb :show_array
end
# api/v1 routes
get '/api/v1/reviews/?:hash?' do |id|
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json

  if params[:url] && id.nil?
    url = params[:url]
    response = HTTParty.get(url)
    shasum = Digest::SHA2.hexdigest(response.body)
    id = shasum
  end


  db = settings.mongo_db
  if id.start_with? "Qm"
    documents = db.find( { "ipfs-hash": "#{id}"}).to_a
  else
    documents = db.find( { "sha-256": "#{id}"}).to_a
  end
  (documents || {})

  response = documents.map{|doc|
    {
      "id": doc["id"],
      "review-society": doc["review-society"],
      "date": doc["date"],
      "badge-url": doc["badge-url"],
      "badge-rubric": doc["badge-rubric"],
      "review-report": doc["review-report"],
      "review-summary": doc["review-summary"],
      "sha-256": doc["sha-256"],
      "ipfs-hash": doc["ipfs-hash"],
      "submitted-url": doc["submitted-url"]
    }

  }.to_json
end
get '/api/v1/review/:id' do |id|
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json
  db = settings.mongo_db

  doc = db.find( { "id": "#{id}" } ).to_a.first
  (doc || {})

  response = {
      "id": doc["id"],
      "review-society": doc["review-society"],
      "date": doc["date"],
      "badge-url": doc["badge-url"],
      "badge-rubric": doc["badge-rubric"],
      "review-report": doc["review-report"],
      "review-summary": doc["review-summary"],
      "sha-256": doc["sha-256"],
      "ipfs-hash": doc["ipfs-hash"],
      "submitted-url": doc["submitted-url"]
  }.to_json
end
helpers do
  # a helper method to turn a string ID
  # representation into a BSON::ObjectId
  def object_id val
    begin
      BSON::ObjectId.from_string(val)
    rescue BSON::ObjectId::Invalid
      nil
    end
  end

  def document_by_id id
    id = object_id(id) if String === id
    if id.nil?
      {}.to_json
    else
      document = settings.mongo_db.find(:_id => id).to_a.first
      (document || {}).to_json
    end
  end
end
