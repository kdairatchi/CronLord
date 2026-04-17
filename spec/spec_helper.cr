require "spec"
require "http/server"
require "../src/cronlord"

# Shared in-memory SQLite for specs that touch Run/Job persistence.
def ensure_test_db : Nil
  return if CronLord::DB.opened?
  dbfile = File.tempname("cronlord-spec", ".db")
  CronLord::DB.open(dbfile)
  CronLord::DB.migrate!(log: false)
end

ensure_test_db

# Build a synthetic HTTP::Server::Context for auth helpers that only need
# request headers + a raw body. Kemal uses the same class under the hood.
def build_env(body : String = "", headers : Hash(String, String) = {} of String => String,
              method : String = "POST", path : String = "/") : HTTP::Server::Context
  req_headers = HTTP::Headers.new
  headers.each { |k, v| req_headers[k] = v }
  request = HTTP::Request.new(method, path, req_headers, body)
  response = HTTP::Server::Response.new(IO::Memory.new)
  HTTP::Server::Context.new(request, response)
end
