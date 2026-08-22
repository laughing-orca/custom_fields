# Single-process profiler for the custom_fields library.
#
#   ruby demo/profile.rb
#   DB_NAME=custom_fields_profile SEED=400 ruby demo/profile.rb
#
# Unlike stress_test.rb (concurrent, multi-process), this runs the same operation
# mix single-threaded and in-process so the profilers see everything. Sampling
# profilers cannot follow the stress test's Sidekiq subprocesses, and the
# allocation tracker is process-wide, so a deterministic in-process run gives the
# cleanest attribution of where the library's Ruby runtime and memory go.
#
# It reports, in order:
#   1. per-operation wall time + allocations (stdlib GC.stat, no gems)
#   2. StackProf (cpu) Ruby runtime hotspots
#   3. MemoryProfiler allocation breakdown by gem / file / location
#   4. a process summary (RSS, GC runs/time, lifetime allocations)
#
# stackprof + memory_profiler are dev-only tools and are intentionally NOT in the
# Gemfile (they would otherwise leak into the gem's dependency surface). Install
# them into the active gemset once with:
#
#   gem install stackprof memory_profiler
#
# This file locates them on $LOAD_PATH itself so `bundle exec` can load them
# without a Gemfile entry. Output of a sample run lives in demo/profile.output.txt.

def load_profiler(name)
  require name
rescue LoadError
  base = File.expand_path("~/.rvm/gems/ruby-#{RUBY_VERSION}@custom_fields/gems")
  dir = Dir[File.join(base, "#{name}-*/lib")].max
  raise "#{name} not installed (run: gem install #{name})" unless dir
  $LOAD_PATH.unshift(dir)
  require name
end
load_profiler("stackprof")
load_profiler("memory_profiler")

ENV["DB_NAME"]   ||= "custom_fields_profile"
ENV["REDIS_URL"] ||= "redis://localhost:6379/13"
require_relative "boot"
require_relative "schema"
ActiveRecord::Base.logger = nil
srand(1234)

SEED  = Integer(ENV.fetch("SEED", 400))
ITERS = Integer(ENV.fetch("ITERS", 100))

# ---------------------------------------------------------------- seed (mirrors stress_test)
PRIORITIES = %w[low medium high urgent p0 p1 p2].freeze
TREE = [
  { value: "US", children: [{ value: "CA", children: [{ value: "LA" }, { value: "SF" }] },
                            { value: "TX", children: [{ value: "AU" }] }] },
  { value: "IN", children: [{ value: "KA", children: [{ value: "BLR" }] },
                            { value: "KL", children: [{ value: "COK" }] }] },
].freeze

def sample_place
  co = TREE.sample
  st = co[:children].sample
  ci = st[:children].sample
  [co[:value], st[:value], ci[:value]]
end

puts "== seeding #{SEED} instances into #{ENV['DB_NAME']} =="
form = Form.create_form(name: "Prof", latest_version: 1)
CustomFields::FieldEditor.new(form).create_fields([
  { name: "priority", field_type: "text", choices: true, choice_match: :value },
  { name: "country",  field_type: "text", choices: true, choice_match: :value },
  { name: "state",    field_type: "text", choices: true, choice_match: :value, depends_on: "country" },
  { name: "city",     field_type: "text", choices: true, choice_match: :value, depends_on: "state" },
  { name: "note",     field_type: "text" },
])
CustomFields::FieldEditor.new(form).create_fields((1..6).map { |i| { name: "num#{i}", field_type: "integer" } })
f = form.fields_at(1).index_by(&:name)
ce = CustomFields::ChoiceEditor.new(form)
ce.set_choices(f["priority"], PRIORITIES)
ce.set_dependent_choices([f["country"], f["state"], f["city"]], TREE)
PRIORITY_ID = f["priority"].id

ied = CustomFields::InstanceEditor.new(form)
SEED.times do |i|
  co, st, ci = sample_place
  ied.create_instance(values: { "priority" => PRIORITIES.sample, "country" => co, "state" => st, "city" => ci,
                                "note" => "seed#{i}", "num1" => i, "num6" => i * 6 })
end
puts "seeded #{form.instances.count} instances at v#{form.latest_version}"

# ---------------------------------------------------------------- operation mix
OPS = {
  create: -> {
    co, st, ci = sample_place
    CustomFields::InstanceEditor.new(form).create_instance(
      values: { "priority" => PRIORITIES.sample, "country" => co, "state" => st, "city" => ci, "note" => "c#{rand(1000)}" })
  },
  update: -> {
    live = form.instances.order(Arel.sql("RAND()")).first or next
    co, st, ci = sample_place
    CustomFields::InstanceEditor.new(form).update_instance(
      live, values: { "country" => co, "state" => st, "city" => ci, "note" => "u#{rand(1000)}", "num6" => rand(1000) })
  },
  filter: -> { CustomFields::InstanceFilter.new(form).filter_instances(priority: PRIORITIES.sample).values },
  read: -> {
    inst = form.instances.order(Arel.sql("RAND()")).first or next
    inst.field_values(inst.form_version, form.cached_fields(inst.form_version))
  },
  choice_add: -> { CustomFields::ChoiceEditor.new(form).add_choices(form.fields.find_by(id: PRIORITY_ID), ["x#{rand(20)}"]) },
}.freeze

def run_mix(n)
  keys = OPS.keys
  n.times { |i| OPS[keys[i % keys.size]].call }
end

run_mix(OPS.size) # warm caches / connection

# ---------------------------------------------------------------- 1) per-op wall time + allocations
puts "\n================ PER-OPERATION: wall time + allocations (#{ITERS} iters each) ================"
printf "%-12s %12s %14s %16s\n", "op", "ms/op", "allocs/op", "ms total(#{ITERS})"
OPS.each do |name, op|
  GC.start
  a0 = GC.stat(:total_allocated_objects)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ITERS.times { op.call }
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  a1 = GC.stat(:total_allocated_objects)
  ms = (t1 - t0) * 1000
  printf "%-12s %12.3f %14d %16.1f\n", name, ms / ITERS, (a1 - a0) / ITERS, ms
end

# ---------------------------------------------------------------- 2) runtime hotspots (stackprof cpu)
puts "\n================ STACKPROF (cpu) — Ruby runtime hotspots over 1500 mixed ops ================"
results = StackProf.run(mode: :cpu, interval: 500) { run_mix(1500) }
StackProf::Report.new(results).print_text(false, 30)

# ---------------------------------------------------------------- 3) allocation breakdown (memory_profiler)
puts "\n================ MEMORY_PROFILER — allocations over 200 mixed ops ================"
GC.start
report = MemoryProfiler.report { run_mix(200) }
report.pretty_print(scale_bytes: true, normalize_paths: true)

# ---------------------------------------------------------------- 4) process summary
puts "\n================ PROCESS SUMMARY ================"
rss_kb = `ps -o rss= -p #{Process.pid}`.to_i
printf "RSS: %.1f MB | GC runs: %d | GC time: %d ms | lifetime allocated objects: %d\n",
       rss_kb / 1024.0, GC.stat(:count), GC.stat(:time), GC.stat(:total_allocated_objects)
