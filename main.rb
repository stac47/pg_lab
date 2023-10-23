# frozen_string_literal: true

require "active_record"
require "active_support"

LOGGER = ActiveSupport::Logger.new($stdout, level: :debug)
ActiveRecord::Base.logger = LOGGER

def timeit(id)
  start_time = Time.now
  LOGGER.debug("Starting #{id} at: #{start_time}")
  ret = yield
  end_time = Time.now
  LOGGER.debug("End #{id} at #{end_time}. Duration: #{end_time - start_time} seconds")

  ret
end

connection_params = {
  adapter: "postgresql",
  database: "test",
  host: "localhost",
  user: "postgres",
  password: "test"
}

ActiveRecord::Base.establish_connection(connection_params)

class Person < ActiveRecord::Base
end

def prepare_db
  LOGGER.debug("Preparing the database")
  connection = ActiveRecord::Base.connection
  connection.create_table "people", force: true do |t|
    t.string :name
  end
  connection.execute <<~SQL
    DROP TRIGGER IF EXISTS slow_before ON people;
    DROP TRIGGER IF EXISTS slow_after ON people;
    DROP FUNCTION IF EXISTS slow_request();

    CREATE FUNCTION slow_request()
      RETURNS TRIGGER
      LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM pg_sleep(1);
      RETURN NEW;
    END
    $$;

    CREATE TRIGGER slow_before
      AFTER INSERT ON people
      FOR EACH ROW
      EXECUTE PROCEDURE slow_request();
    CREATE TRIGGER slow_after
      AFTER INSERT ON people
      FOR EACH ROW
      EXECUTE PROCEDURE slow_request();
  SQL
  LOGGER.debug("Database prepared")
end

def start_worker(name)
  Thread.new do
    3.times do |iteration|
      timeit(name) do
        Person.create!(name: "#{name} #{iteration}")
      end
    end
  end
end

class DoDdl < ActiveRecord::Migration[7.1]
  def up
    timeit("up") do
      execute <<~SQL
        LOCK TABLE people IN ACCESS EXCLUSIVE MODE;
        SELECT pg_sleep(5);
        -- ALTER TABLE people RENAME TO people_old;
        -- ALTER TABLE people_old RENAME TO people;
      SQL
    end
  end

  def down
  end
end

prepare_db

threads = []
threads << start_worker("alice")
threads << start_worker("bob")

sleep(1)

DoDdl.new.migrate(:up)
sleep 2
DoDdl.new.migrate(:down)

threads.each { |th| th.join }
