# Parallel stress test for the whole library against real MySQL and 2 real
# Sidekiq workers.
#
#   ruby demo/stress_test.rb
#   THREADS=3 ITERS=200 ruby demo/stress_test.rb
#
# It seeds one form, boots 2 Sidekiq workers (which run the pruner), hammers
# every public operation from many threads, then checks the data is consistent.
# Transient (retryable) errors are counted, and whenever a deadlock or lock-wait
# timeout happens the "LATEST DETECTED DEADLOCK" section is pulled from MySQL.
#
# Output is written to demo/ for inspection: stress_test.log (this process) and
# stress_sidekiq_1.log / stress_sidekiq_2.log (the two worker processes).

# Isolate from the interactive demo (custom_fields_demo / redis db 0).
ENV["DB_NAME"] ||= "custom_fields_stress"
ENV["REDIS_URL"] ||= "redis://localhost:6379/15"

require_relative "boot"
require_relative "schema"
require "sidekiq/api"

ActiveRecord::Base.logger = nil

# mirror everything this process prints to demo/stress_test.log for later inspection
class Tee
  def initialize(*ios) = @ios = ios
  def write(*a) = @ios.map { |io| io.write(*a) }.last
  def print(*a) = @ios.each { |io| io.print(*a) }
  def puts(*a) = @ios.each { |io| io.puts(*a) }
  def flush = @ios.each(&:flush)
  def sync = true
  def close = nil

  def sync=(value)
    @ios.each { |io| io.sync = value }
  end
end

MAIN_LOG = File.open(File.join(__dir__, "stress_test.log"), "w")
MAIN_LOG.sync = true
$stdout = Tee.new(STDOUT, MAIN_LOG)

WORKERS = 2
THREADS = Integer(ENV.fetch("THREADS", 2))   # threads per operation
ITERS   = Integer(ENV.fetch("ITERS", 120))
SEED    = Integer(ENV.fetch("SEED", 200))

CustomFields.configure do |c|
  c.max_form_versions      = 3
  c.max_instance_revisions = 3
  c.prune_version_buffer   = 0
  c.batch_size             = 50
end
ActiveRecord::Base.establish_connection(DB_CONFIG.merge(database: DB_NAME, pool: 30, checkout_timeout: 20))

# ---------------------------------------------------------------- shared state
STATS     = Hash.new(0)
TRANSIENT = Hash.new(0)
ERRORS    = Queue.new
DEADLOCKS = []
MX        = Mutex.new

def bump(key) = MX.synchronize { STATS[key] += 1 }

def deadlock?(e)
  e.is_a?(ActiveRecord::Deadlocked) || e.is_a?(ActiveRecord::LockWaitTimeout) || e.message =~ /deadlock|lock wait timeout/i
end

# InnoDB keeps only the latest deadlock server-wide, so this catches deadlocks
# from any process (test threads or the Sidekiq pruner).
def capture_deadlock(source)
  MX.synchronize do
    return if DEADLOCKS.size >= 10
    row = ActiveRecord::Base.connection.execute("SHOW ENGINE INNODB STATUS").first
    text = row.is_a?(Hash) ? row["Status"] : Array(row)[2].to_s
    detail = text[/LATEST DETECTED DEADLOCK.*?(?=-{10,}\nTRANSACTIONS|\z)/m]&.strip || "(no deadlock section)"
    DEADLOCKS << { source: source, detail: detail }
  end
end

# Count every retry the InstanceEditor makes internally.
module CountRetries
  def with_retries(max, fallback_error: "E003", &blk)
    super(max, fallback_error: fallback_error) do
      blk.call
    rescue *CustomFields::Retryable::RETRYABLE_ERRORS => e
      MX.synchronize { TRANSIENT[e.class.name] += 1 }
      capture_deadlock("instance_editor") if deadlock?(e)
      raise
    end
  end
end
CustomFields::InstanceEditor.prepend(CountRetries)

# ---------------------------------------------------------------- seed
PRIORITIES = %w[low medium high urgent p0 p1 p2].freeze
TREE = [
  { value: "US", children: [{ value: "CA", children: [{ value: "LA" }, { value: "SF" }] },
                            { value: "TX", children: [{ value: "AU" }] }] },
  { value: "IN", children: [{ value: "KA", children: [{ value: "BLR" }] },
                            { value: "KL", children: [{ value: "COK" }] }] },
].freeze
# an alternate tree so tree_reshape actually deactivates/reactivates values under concurrent writers
ALT_TREE = [
  { value: "US", children: [{ value: "WA", children: [{ value: "SEA" }] }] },
  { value: "IN", children: [{ value: "KA", children: [{ value: "MYS" }] }] },
].freeze

def sample_place
  co = TREE.sample
  st = co[:children].sample
  ci = st[:children].sample
  [co[:value], st[:value], ci[:value]]
end

puts "== seeding #{SEED} instances into #{DB_NAME} =="
form = Form.create_form(name: "Stress", latest_version: 1)
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
COUNTRY_ID  = f["country"].id
STATE_ID    = f["state"].id
CITY_ID     = f["city"].id
FORM_ID     = form.id

ied = CustomFields::InstanceEditor.new(form)
SEED.times do |i|
  co, st, ci = sample_place
  ied.create_instance(values: { "priority" => PRIORITIES.sample, "country" => co, "state" => st, "city" => ci,
                                "note" => "seed#{i}", "num1" => i, "num6" => i * 6 })
end
puts "seeded #{form.instances.count} instances at v#{form.latest_version}"

# ---------------------------------------------------------------- sidekiq workers
def sidekiq_pending
  Sidekiq::Queue.new("default").size + Sidekiq::RetrySet.new.size +
    Sidekiq::ScheduledSet.new.size + Sidekiq::Workers.new.size
end

Sidekiq.redis { |c| c.flushdb }
WORKER_LOGS = Array.new(WORKERS) { |i| File.join(__dir__, "stress_sidekiq_#{i + 1}.log") }
pids = WORKER_LOGS.map do |wlog|
  Process.spawn("bundle", "exec", "sidekiq", "-r", "./demo/boot.rb", "-c", "1", "-q", "default",
                chdir: File.expand_path("..", __dir__), out: wlog, err: wlog)
end
print "starting #{WORKERS} sidekiq workers"
sleep 0.3 until Sidekiq::ProcessSet.new.size >= WORKERS
puts " up (pids #{pids.join(', ')})"

# ---------------------------------------------------------------- operations
OPERATIONS = {
  create: ->(fm) {
    co, st, ci = sample_place
    r = CustomFields::InstanceEditor.new(fm).create_instance(
      values: { "priority" => PRIORITIES.sample, "country" => co, "state" => st, "city" => ci, "note" => "c#{rand(1000)}" })
    bump(r.success? ? :create_ok : :"create_#{r.error[:code]}")
  },
  update: ->(fm) {
    live = fm.instances.order(Arel.sql("RAND()")).first or return
    co, st, ci = sample_place
    r = CustomFields::InstanceEditor.new(fm).update_instance(
      live, values: { "country" => co, "state" => st, "city" => ci, "note" => "u#{rand(1000)}", "num6" => rand(1000) })
    bump(r.success? ? :update_ok : :"update_#{r.error[:code]}")
  },
  filter: ->(fm) {
    CustomFields::InstanceFilter.new(fm).filter_instances(priority: PRIORITIES.sample).values
    bump(:filter_ok)
  },
  read: ->(fm) {
    inst = fm.instances.order(Arel.sql("RAND()")).first or return
    inst.field_values(inst.form_version, fm.cached_fields(inst.form_version))
    bump(:read_ok)
  },
  field_churn: ->(fm) {   # bumps versions -> enqueues the pruner on the workers
    if rand < 0.5
      bump(CustomFields::FieldEditor.new(fm).create_fields([{ name: "dyn_#{SecureRandom.hex(3)}", field_type: "text" }]).success? ? :field_add_ok : :field_add_fail)
    else
      dyn = fm.cached_fields(fm.latest_version).map(&:name).select { |n| n.start_with?("dyn") }
      bump(dyn.any? && CustomFields::FieldEditor.new(fm).delete_fields([dyn.sample]).success? ? :field_del_ok : :field_del_noop)
    end
  },
  choice_churn: ->(fm) {
    ce = CustomFields::ChoiceEditor.new(fm)
    pr = fm.fields.find_by(id: PRIORITY_ID) or return
    case rand(3)
    when 0 then bump(ce.add_choices(pr, ["x#{rand(20)}"]).success? ? :choice_add_ok : :choice_add_fail)
    when 1 then bump(ce.rename_choice(pr, "x#{rand(20)}", "x#{rand(20)}").success? ? :choice_rename_ok : :choice_rename_noop)
    else        bump(ce.delete_choices(pr, ["x#{rand(20)}"]).success? ? :choice_del_ok : :choice_del_noop)
    end
  },
  # cyclic + self-referential parent/depends_on: the editor must break the cycle, not loop or persist one
  cyclic_fields: ->(fm) {
    a, b, c = %w[a b c].map { |x| "cy_#{x}_#{SecureRandom.hex(3)}" }
    fe = CustomFields::FieldEditor.new(fm)
    r = fe.create_fields([
      { name: a, field_type: "text", depends_on: b },           # a -> b
      { name: b, field_type: "text", depends_on: a, parent: b },# b -> a (cycle) + b -> b (self)
      { name: c, field_type: "text", parent: a },               # c -> a
    ])
    bump(r.success? || r.errors.any? ? :cyclic_handled : :cyclic_bad)
    fe.delete_fields([a, b, c])   # recycle the text slots
  },
  # reshape the dependent tree while creators/updaters are using its values
  tree_reshape: ->(fm) {
    co, st, ci = [COUNTRY_ID, STATE_ID, CITY_ID].map { |id| fm.fields.find_by(id: id) }
    return unless co && st && ci
    bump(CustomFields::ChoiceEditor.new(fm).set_dependent_choices([co, st, ci], [TREE, ALT_TREE].sample).success? ? :reshape_ok : :reshape_fail)
  },
  # invalid inputs must be rejected cleanly, not raise
  misuse: ->(fm) {
    ied = CustomFields::InstanceEditor.new(fm)
    bad = ied.create_instance(values: { "country" => "Atlantis", "state" => "Nowhere" })
    bump(bad.failed? && bad.error[:code] == "E001" ? :misuse_choice_rejected : :misuse_choice_unexpected)

    fe = CustomFields::FieldEditor.new(fm)
    r = fe.create_fields([{ name: "mis#{rand(50)}", field_type: "text", parent: "ghost_#{rand(1000)}" }])
    bump(r.errors.any? ? :misuse_dep_rejected : :misuse_dep_unexpected)

    d = fe.delete_fields(["missing_#{rand(1000)}"])
    bump(d.errors.any? ? :misuse_delete_rejected : :misuse_delete_unexpected)
  },
  # deleting a dropdown must cascade to its dependent child via the depends_on closure (retiring both)
  cascade_delete: ->(fm) {
    fe = CustomFields::FieldEditor.new(fm)
    root  = "cd_r_#{SecureRandom.hex(3)}"
    child = "cd_c_#{SecureRandom.hex(3)}"
    created = fe.create_fields([
      { name: root,  field_type: "text", choices: true, choice_match: :value },
      { name: child, field_type: "text", choices: true, choice_match: :value, depends_on: root },
    ])
    if created.results.size == 2
      CustomFields::ChoiceEditor.new(fm).set_dependent_choices(
        [fm.fields.find_by(name: root), fm.fields.find_by(name: child)], [{ value: "x", children: [{ value: "y" }] }])
      del = fe.delete_fields([root])
      active = fm.active_fields.pluck(:name)
      bump(del.success? && !active.include?(root) && !active.include?(child) ? :cascade_ok : :cascade_bad)
    else
      fe.delete_fields([root, child])
      bump(:cascade_skip)
    end
  },
  # renaming a choice onto an existing value must be rejected (unique violation caught), never raised
  rename_collision: ->(fm) {
    ce = CustomFields::ChoiceEditor.new(fm)
    pr = fm.fields.find_by(id: PRIORITY_ID) or return
    ce.add_choices(pr, %w[rc_a rc_b])
    r = ce.rename_choice(pr, "rc_a", "rc_b")
    bump(r.success? ? :rename_ok : :"rename_#{r.error[:code]}")
  },
}.freeze

puts "== workload: #{OPERATIONS.size} operations x #{THREADS} threads x #{ITERS} iters =="
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
threads = OPERATIONS.flat_map do |name, op|
  Array.new(THREADS) do
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ITERS.times do
          op.call(Form.find(FORM_ID))
        rescue => e
          capture_deadlock(name.to_s) if deadlock?(e)
          ERRORS << "#{name}: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
threads.each(&:join)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

# ---------------------------------------------------------------- drain & stop
print "draining sidekiq"
sleep 0.5 until sidekiq_pending.zero?
puts " done"
20.times { break unless form.reload.prune_due?; CustomFields::FieldVersionPruner.new(form).call }
pids.each { |pid| Process.kill("TERM", pid) rescue nil }
pids.each { |pid| Process.wait(pid) rescue nil }

unhandled = [].tap { |a| a << ERRORS.pop until ERRORS.empty? }

# ---------------------------------------------------------------- report
puts "\n== results =="
puts "wall time: #{elapsed.round(2)}s"
puts "ops:       #{STATS.sort.to_h}"
puts "transient: #{TRANSIENT.to_h}"
puts "unhandled: #{unhandled.size}"
unhandled.first(5).each { |e| puts "  - #{e}" }
DEADLOCKS.each_with_index do |d, i|
  puts "\n-- deadlock ##{i + 1} (source=#{d[:source]}) --\n#{d[:detail]}"
end

# ---------------------------------------------------------------- consistency
puts "\n== consistency =="
FAILS = []
def check(label)
  ok, detail = yield
  puts(ok ? "  [PASS] #{label}" : "  [FAIL] #{label} -- #{detail}")
  FAILS << label unless ok
rescue => e
  puts "  [FAIL] #{label} -- #{e.class}: #{e.message}"
  FAILS << label
end

check("no unhandled worker errors") { [unhandled.empty?, "#{unhandled.size} errors"] }

check("one live row per lineage") do
  [form.instances.group(:instance_version_id).having("COUNT(*) > 1").count.empty?, "duplicate lineages"]
end

check("no orphan data-store rows (live + previous)") do
  live = form.class.data_store_classes.sum { |s| s.where.not(instance_id: Form::Instance.select(:id)).count }
  prev = form.class.previous_data_store_classes.sum { |s| s.where.not(instance_id: Form::PreviousInstance.select(:id)).count }
  [(live + prev).zero?, "live=#{live} prev=#{prev}"]
end

check("at most one store row per live instance") do
  ids = form.instances.pluck(:id)
  dups = form.slot_layout.stores.sum { |s| s.where(instance_id: ids).group(:instance_id).having("COUNT(*) > 1").count.size }
  [dups.zero?, "#{dups} duplicates"]
end

check("live instances on a covered, retained version") do
  cutoff = form.min_retained_form_version
  bad = form.instances.distinct.pluck(:form_version).reject { |v| v >= cutoff && form.fields_at(v).exists? }
  [bad.empty?, "bad versions #{bad.inspect} (cutoff #{cutoff})"]
end

check("history revisions sit below the live revision") do
  live = form.instances.pluck(:instance_version_id, :instance_version).to_h
  bad = form.previous_instances.pluck(:instance_version_id, :instance_version).count { |vid, ver| live[vid] && ver >= live[vid] }
  [bad.zero?, "#{bad} history rows at/above live"]
end

check("revisions per lineage within max_instance_revisions") do
  keep = CustomFields.configuration.max_instance_revisions
  [form.previous_instances.group(:instance_version_id).count.none? { |_, n| n > keep }, "some lineage exceeds #{keep}"]
end

check("live instances have unique, positive sequence numbers") do
  seqs = form.instances.pluck(:sequence_number)
  [seqs.all? { |n| n&.positive? } && seqs.uniq.size == seqs.size, "count=#{seqs.size} distinct=#{seqs.uniq.size}"]
end

check("history rows share their lineage's sequence number") do
  live = form.instances.pluck(:instance_version_id, :sequence_number).to_h
  bad = form.previous_instances.pluck(:instance_version_id, :sequence_number).count { |vid, s| live[vid] && live[vid] != s }
  [bad.zero?, "#{bad} mismatched"]
end

check("active child choices point at active parents") do
  bad = 0
  form.fields.where(has_choices: true).where.not(depends_on_field_id: 0).each do |fld|
    parents = Form::Choice.where(field_id: fld.depends_on_field_id, active: true).pluck(:id).to_set
    bad += Form::Choice.where(field_id: fld.id, active: true).count { |c| !parents.include?(c.parent_id) }
  end
  [bad.zero?, "#{bad} misparented"]
end

check("field_values matches raw slot storage") do
  layout = form.slot_layout
  bad = []
  form.instances.order(Arel.sql("RAND()")).limit(40).each do |inst|
    flds = form.cached_fields(inst.form_version)
    vals = inst.field_values(inst.form_version, flds, slot_layout: layout)
    raw = layout.read(inst)
    flds.each { |fld| bad << [inst.id, fld.name] if fld.valid_at?(inst.form_version) && !vals[fld.name].nil? && raw[fld.slot].to_s != vals[fld.name].to_s }
  end
  [bad.empty?, "mismatches #{bad.first(3)}"]
end

check("no persisted field dependency cycles") do
  succ = Hash.new { |h, k| h[k] = [] }
  form.fields.pluck(:id, :parent_id, :depends_on_field_id).each do |id, parent, dep|
    succ[id] << parent unless parent.zero?
    succ[id] << dep unless dep.zero?
  end
  visiting, done, cyclic = {}, {}, false
  dfs = lambda do |n|
    visiting[n] = true
    succ[n].each do |m|
      cyclic = true if visiting[m]
      dfs.call(m) unless done[m] || visiting[m]
    end
    visiting[n] = false
    done[n] = true
  end
  succ.keys.each { |n| dfs.call(n) unless done[n] }
  [!cyclic, "a parent/depends_on cycle was persisted"]
end

puts "\n== summary =="
puts(FAILS.empty? ? "ALL PASS" : "#{FAILS.size} FAILED: #{FAILS.join(', ')}")
puts "logs: #{MAIN_LOG.path} | #{WORKER_LOGS.join(' | ')}"
MAIN_LOG.close
exit(FAILS.empty? ? 0 : 1)
