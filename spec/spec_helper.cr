require "spec"
require "../src/cronlord"

# Shared in-memory SQLite for specs that touch Run/Job persistence.
# Each spec file that needs it calls `ensure_test_db`.
def ensure_test_db : Nil
  return if CronLord::DB.opened?
  dbfile = File.tempname("cronlord-spec", ".db")
  CronLord::DB.open(dbfile)
  CronLord::DB.migrate!(log: false)
end
