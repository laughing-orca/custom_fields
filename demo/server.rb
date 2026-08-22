require_relative "boot"
require "webrick"
require "cgi"
require "json"

ActiveRecord::Base.logger = Logger.new($stdout)
PORT = (ENV["PORT"] || 4567).to_i

def h(text) = CGI.escapeHTML(text.to_s)

def page(title, body)
  "<html><head><title>#{h title}</title></head><body>" \
  "<a href=\"/\">forms</a><hr>" \
  "<h2>#{h title}</h2>#{body}" \
  "</body></html>"
end

def table(headers, rows)
  return "<p>none</p>" if rows.empty?

  head = headers.map { |c| "<th>#{h c}</th>" }.join
  body = rows.map { |row| "<tr>#{row.map { |c| "<td>#{c}</td>" }.join}</tr>" }.join
  "<table border=\"1\" cellpadding=\"4\"><tr>#{head}</tr>#{body}</table>"
end

def kv(values) = values.compact.map { |k, v| "#{k}=#{v}" }.join(" ")

def audits_table(audits)
  table(["time", "entity", "action", "entity_id", "fv", "iv", "patch"],
        audits.map do |a|
    stored = a.patch
    json = stored.is_a?(String) ? stored : JSON.generate(stored)
    [h(a.created_at.strftime("%H:%M:%S")), h(a.entity_type), h(a.action), a.entity_id,
     a.form_version ? "v#{a.form_version}" : "-", a.instance_version || "-", "<code>#{h json}</code>"]
  end)
end

def field_types(form) = form.cached_field_types

def slot_names(form) = field_types(form).flat_map(&:slot_names)

def latest_fields(form) = form.cached_fields(form.latest_version).sort_by(&:id)

def field_control(form, field, current = nil)
  options = choice_options(form, field)
  return "<input name=\"v_#{h field.name}\" size=\"12\" value=\"#{h current}\">" if options.empty?

  picks = options.map do |value, label|
    selected = !current.nil? && value.to_s == current.to_s
    "<option value=\"#{h value}\"#{" selected" if selected}>#{h label}</option>"
  end
  "<select name=\"v_#{h field.name}\"><option value=\"\">-</option>#{picks.join}</select>"
end

def choice_options(form, field)
  return [] unless field.has_choices

  rows = Form::Choice.cached_choices(field.id)
  parents = parent_choices_by_id(form, field)
  rows.map do |c|
    label = c.parent_id.zero? ? c.value : "#{parents[c.parent_id]&.value} > #{c.value}"
    [c.value, label]
  end
end

# a form's value inputs laid out as a field/value table, prefilled from current
def input_table(form, fields, current = {})
  table(["field", "value"], fields.map { |f| [h(f.name), field_control(form, f, current[f.name])] })
end

def input_values(revision, fields, slot_layout = nil)
  stored = revision.field_values(revision.form_version, fields, slot_layout: slot_layout)
  fields.each_with_object({}) do |f, out|
    token = stored[f.name]
    out[f.name] = if f.has_choices && f.match_type == :id && !token.nil?
        Form::Choice.cached_choices_by_id(f.id)[token.to_s]&.value
      else
        token
      end
  end
end

# column header per slot: the current form version's field name for it, else "(not in use)"
def slot_headers(form, slots)
  by_slot = form.cached_fields(form.latest_version).to_h { |f| [f.slot, f.name] }
  slots.map { |s| h(by_slot[s] || "(not in use)") }
end

# a dependent dropdown's choices are parented into the target field's choices,
# so resolve parent labels from that field's active choices
def parent_choices_by_id(form, field)
  return {} unless field.depends_on_field_id.positive?

  parent_field = latest_fields(form).find { |f| f.id == field.depends_on_field_id }
  return {} unless parent_field&.has_choices

  Form::Choice.cached_choices(parent_field.id).index_by(&:id)
end

# ---------------------------------------------------------------- pages

def forms_index
  rows = Form.order(:id).map do |f|
    ["<a href=\"/form?id=#{f.id}\">#{h f.name}</a>", "v#{f.latest_version}",
     f.cached_fields(f.latest_version).size, f.instances.count,
     "<form method=\"post\" action=\"/delete_form\" onsubmit=\"return confirm('Delete #{h f.name} and all its data?')\">" \
     "<input type=\"hidden\" name=\"form_id\" value=\"#{f.id}\"><input type=\"submit\" value=\"delete\"></form>"]
  end

  page("forms", table(["name", "latest", "fields", "instances", ""], rows) + <<~HTML)
    <hr><h3>new form</h3>
    <form method="post" action="/create_form">
      name <input name="name"> <input type="submit" value="create">
    </form>
    <h3>example form</h3>
    <p>a section field grouping plain fields, plus a three level dependent dropdown</p>
    <form method="post" action="/seed_example">
      <input type="submit" value="create example form">
    </form>
  HTML
end

def field_depth(field, by_id, seen = 0)
  parent = by_id[field.parent_id]
  return seen if parent.nil? || seen > 10

  field_depth(parent, by_id, seen + 1)
end

def field_kind(field, children)
  return "section" if field.field_type == "section"
  return "dropdown (dependent)" if field.has_choices && field.depends_on_field_id.positive?
  return "dropdown" if field.has_choices
  return "parent" if children.any?

  "plain"
end

def form_page(form)
  fields = latest_fields(form)
  by_id = fields.index_by(&:id)

  body = +""
  body << "<p>types: " + field_types(form).map { |t| "#{h t.name}&times;#{t.max_slots}" }.join(" &middot; ") + "</p>"

  children_of = fields.group_by(&:parent_id)
  body << "<h3>fields at v#{form.latest_version} &middot; indent = parent_id, \"dep\" = depends_on_field_id</h3>"
  body << table(["id", "field", "kind", "type", "slot", "from", "parent", "dep", "choices", "match"],
                fields.map do |f|
    indent = "&nbsp;&nbsp;" * field_depth(f, by_id)
    [f.id, "#{indent}#{h f.name}", h(field_kind(f, children_of[f.id] || [])),
     h(f.field_type), h(f.slot), "v#{f.valid_from_version}",
     f.parent_id.zero? ? "-" : h(by_id[f.parent_id]&.name),
     f.depends_on_field_id.zero? ? "-" : h(by_id[f.depends_on_field_id]&.name),
     f.has_choices ? "yes" : "-",
     f.has_choices ? h(f.match_type) : "-"]
  end)

  body << <<~HTML
    <form method="post" action="/add_field"><input type="hidden" name="form_id" value="#{form.id}">
      + name <input name="name" size="10"> type <input name="field_type" value="text" size="6">
      parent <input name="parent" size="8"> dep <input name="depends_on" size="8">
      choices <input type="checkbox" name="choices" value="1">
      match <select name="choice_match"><option value="value">value</option><option value="id">id</option></select>
      <input type="submit" value="add field"></form>
    <form method="post" action="/delete_field"><input type="hidden" name="form_id" value="#{form.id}">
      - name <input name="name" size="10"> <input type="submit" value="delete (bumps version, cascades both edges)"></form>
    <h4>bulk add fields</h4>
    <p>one per line: <code>name, type, choices, parent=NAME, depends_on=NAME, match=id</code> &middot; only name required, order after name is free</p>
    <form method="post" action="/add_fields"><input type="hidden" name="form_id" value="#{form.id}">
      <textarea name="specs" rows="5" cols="72" placeholder="tags, text&#10;priority, text, choices, match=value&#10;owner, text, parent=address"></textarea><br>
      <input type="submit" value="add fields"></form>
  HTML

  all_fields = form.fields.order(:valid_from_version, :id).to_a
  latest = form.latest_version
  versions = (all_fields.map(&:valid_from_version).min || latest).upto(latest).to_a
  slots = {}
  all_fields.each do |f|
    (f.valid_from_version...(f.valid_to_version.zero? ? latest + 1 : f.valid_to_version)).each { |v| slots[[f.name, v]] = f.slot if versions.include?(v) }
  end
  body << "<h3>revisions &middot; slot per version, blank = absent at that version</h3>"
  body << table(["field"] + versions.map { |v| "v#{v}" },
                all_fields.map(&:name).uniq.map { |name| [h(name)] + versions.map { |v| h(slots[[name, v]] || "") } })

  dropdowns = fields.select(&:has_choices)
  rows = dropdowns.flat_map do |f|
    choices = Form::Choice.where(field_id: f.id).order(:parent_id, :id).to_a
    parents = Form::Choice.where(id: choices.map(&:parent_id).reject(&:zero?)).index_by(&:id)
    choices.each_with_index.map do |c, i|
      [i.zero? ? "#{h f.name} <b>##{f.id}</b>" : "", c.id, h(c.value),
       c.parent_id.zero? ? "-" : h(parents[c.parent_id]&.value), c.active ? "yes" : "<b>no</b>"]
    end
  end
  body << "<h3>choices &middot; all dropdowns</h3>"
  body << table(["field", "id", "value", "parent choice", "active"], rows)

  body << <<~HTML
    <p>only a field created with "has choices" owns choices. set = reconcile a root dropdown;
    add/delete take a parent value, which a field with a depends_on target must supply.</p>
    <form method="post" action="/set_choices"><input type="hidden" name="form_id" value="#{form.id}">
      set <input name="field" size="8"> = <input name="values" size="24"> <input type="submit" value="go"></form>
    <form method="post" action="/add_choices"><input type="hidden" name="form_id" value="#{form.id}">
      add <input name="field" size="8"> += <input name="values" size="16">
      under <input name="parent" size="8"> <input type="submit" value="go"></form>
    <form method="post" action="/delete_choices"><input type="hidden" name="form_id" value="#{form.id}">
      del <input name="field" size="8"> -= <input name="values" size="16">
      under <input name="parent" size="8"> <input type="submit" value="go"></form>
  HTML

  body << "<h3>instances &middot; values by slot, headed by the current field name</h3>"
  insts = form.instances.order(id: :desc).limit(50).to_a
  live_layout = form.slot_layout
  inst_values = insts.to_h { |i| [i.id, i.slot_values(i.form_version, form.cached_fields(i.form_version), slot_layout: live_layout)] }
  inst_slots = slot_names(form).select { |s| insts.any? { |i| !inst_values[i.id][s].nil? } }
  body << table(["id", "seq", "lineage", "rev", "fv"] + slot_headers(form, inst_slots),
                insts.map do |i|
    ["<a href=\"/instance?id=#{i.id}\">#{i.id}</a>", i.sequence_number, h(i.instance_version_id[0, 8]),
     i.instance_version, "v#{i.form_version}"] +
      inst_slots.map { |s| h(inst_values[i.id][s]) }
  end)

  body << <<~HTML
    <hr><h3>new instance at v#{form.latest_version}</h3>
    <form method="post" action="/create_instance">
      <input type="hidden" name="form_id" value="#{form.id}">
      #{input_table(form, fields)}
      <input type="submit" value="create instance">
    </form>
  HTML

  body << "<h3>audit log &middot; most recent 50 &middot; patch is a JSON-Patch op list</h3>"
  body << audits_table(form.audits.order(id: :desc).limit(50))

  body << <<~HTML
    <hr><h3>danger</h3>
    <form method="post" action="/delete_form" onsubmit="return confirm('Delete #{h form.name} and all its fields, instances, choices and audits?')">
      <input type="hidden" name="form_id" value="#{form.id}">
      <input type="submit" value="delete this form">
    </form>
  HTML

  page("#{form.name} (v#{form.latest_version})", body)
end

def instance_page(inst)
  form = inst.form
  slots = slot_names(form)
  revisions = inst.versions
  live_version = inst.instance_version

  current = form.cached_fields(form.latest_version)
  body = +"<p>lineage #{h inst.instance_version_id} &middot; form <a href=\"/form?id=#{form.id}\">#{h form.name}</a> now at v#{form.latest_version}</p>"

  # live and previous revisions live in different tables, so read each through its own store
  live_layout = form.slot_layout
  prev_layout = form.previous_slot_layout
  layout_for = ->(r) { r.is_a?(Form::PreviousInstance) ? prev_layout : live_layout }

  # the same stored slots, read through each revision's own schema vs the current one.
  # keyed by instance_version: live and previous rows may share an id across tables.
  own_values = revisions.to_h { |r| [r.instance_version, r.slot_values(r.form_version, form.cached_fields(r.form_version), slot_layout: layout_for.call(r))] }
  current_values = revisions.to_h { |r| [r.instance_version, r.slot_values(form.latest_version, current, slot_layout: layout_for.call(r))] }
  shown = slots.select { |s| revisions.any? { |r| !own_values[r.instance_version][s].nil? || !current_values[r.instance_version][s].nil? } }
  headers = ["rev", "fv", "live"] + slot_headers(form, shown)

  live_mark = ->(r) { r.instance_version == live_version ? "<b>yes</b>" : "no" }

  body << "<h3>values read at each revision's own schema version</h3>"
  body << table(headers, revisions.map do |r|
    [r.instance_version, "v#{r.form_version}", live_mark.call(r)] + shown.map { |s| h(own_values[r.instance_version][s]) }
  end)

  body << "<h3>the same slots read at the current schema (v#{form.latest_version})</h3>"
  body << table(headers, revisions.map do |r|
    [r.instance_version, "v#{r.form_version}", live_mark.call(r)] + shown.map { |s| h(current_values[r.instance_version][s]) }
  end)

  body << "<h3>raw slot storage</h3>"
  # slot values live in the data stores, not on the instance row, so read them via each revision's own layout
  stored = revisions.to_h { |r| [r.instance_version, layout_for.call(r).read(r)] }
  used = slots.select { |s| revisions.any? { |r| !stored[r.instance_version][s].nil? } }
  body << table(["rev"] + used, revisions.map { |r| [r.instance_version] + used.map { |s| h(stored[r.instance_version][s]) } })

  now = input_values(inst, current, live_layout)
  body << <<~HTML
    <hr><h3>update live revision (rev #{inst.instance_version}) &middot; prefilled, clearing a box writes nil</h3>
    <form method="post" action="/update_instance">
      <input type="hidden" name="id" value="#{inst.id}">
      #{input_table(form, latest_fields(form), now)}
      <input type="submit" value="update">
    </form>
  HTML

  body << "<h3>audit log for this instance</h3>"
  body << audits_table(form.audits.where(entity_type: "instance", entity_id: inst.id).order(id: :desc))

  body << "<hr><a href=\"/form?id=#{form.id}\">back to form</a>"
  page("instance ##{inst.id}", body)
end

# ---------------------------------------------------------------- actions

# blank_as_nil sends an explicit nil so an update clears the slot; without it a blank
# input is simply omitted and the previous value carries forward.
def submitted_values(query, form, blank_as_nil: false)
  latest_fields(form).each_with_object({}) do |field, values|
    raw = query["v_#{field.name}"]
    next if raw.nil?

    if raw.empty?
      values[field.name] = nil if blank_as_nil
    else
      values[field.name] = raw
    end
  end
end

def split_values(raw) = raw.to_s.split(",").map(&:strip).reject(&:empty?)

# one field per line: "name, type, choices, parent=X, depends_on=Y, match=id"
# only name is required; bare tokens after it set the type, "choices" flags a dropdown
def parse_field_specs(text)
  text.to_s.each_line.filter_map do |line|
    tokens = line.split(",").map(&:strip).reject(&:empty?)
    next if tokens.empty?

    spec = { name: tokens.shift, field_type: "text" }
    tokens.each do |token|
      key, value = token.split("=", 2).map(&:strip)
      case key
      when "choices" then spec[:choices] = true
      when "parent" then spec[:parent] = value
      when "depends_on" then spec[:depends_on] = value
      when "match" then spec[:choice_match] = value
      else spec[:field_type] = key
      end
    end
    spec
  end
end

def destroy_form(form)
  ActiveRecord::Base.transaction do
    form.slot_layout.delete_with_data(form.instances.pluck(:id))
    form.previous_slot_layout.delete_with_data(form.previous_instances.pluck(:id))
    field_ids = form.fields.pluck(:id)
    Form::Choice.where(field_id: field_ids).delete_all if field_ids.any?
    form.fields.delete_all
    Form::Sequence.where(form_id: form.id).delete_all
    form.audits.delete_all
    form.destroy
  end
end

def handle_post(path, query)
  case path
  when "/create_form"
    form = Form.create_form(name: query["name"].presence || "form", latest_version: 1)
    "/form?id=#{form.id}"
  when "/seed_example"
    form = Form.create_form(name: "Example", latest_version: 1)

    editor = CustomFields::FieldEditor.new(form)
    # parent: sets containment (line1/pincode under the address section; the cascade
    # chain also nests, with a plain "gap" field sitting between state and city)
    editor.create_fields([
      { name: "address", field_type: "section" },
      { name: "line1", field_type: "text", parent: "address" },
      { name: "pincode", field_type: "integer", parent: "address" },
      { name: "country", field_type: "text", choices: true, choice_match: :value },
      { name: "state", field_type: "text", choices: true, choice_match: :value, depends_on: "country", parent: "country" },
      { name: "gap", field_type: "text", parent: "state" },
      { name: "city", field_type: "text", choices: true, choice_match: :value, depends_on: "state", parent: "gap" },
      { name: "note", field_type: "text" },
    ])
    fields = latest_fields(form).index_by(&:name)

    choices = CustomFields::ChoiceEditor.new(form)
    choices.set_dependent_choices(
      [fields["country"], fields["state"], fields["city"]],
      [
        { value: "USA", children: [
          { value: "California", children: [{ value: "LA" }, { value: "SF" }] },
          { value: "Texas", children: [{ value: "Austin" }] },
        ] },
        { value: "India", children: [
          { value: "Karnataka", children: [{ value: "Bengaluru" }] },
          { value: "Kerala", children: [{ value: "Kochi" }] },
        ] },
      ]
    )

    instances = CustomFields::InstanceEditor.new(form)
    instances.create_instance(values: { "line1" => "12 Main St", "pincode" => 560001, "country" => "India",
                                        "state" => "Karnataka", "city" => "Bengaluru", "note" => "first" })
    instances.create_instance(values: { "line1" => "9 Market Ave", "pincode" => 94103, "country" => "USA",
                                        "state" => "California", "city" => "SF", "note" => "second" })
    "/form?id=#{form.id}"
  when "/add_field"
    form = Form.find(query["form_id"])
    response = CustomFields::FieldEditor.new(form).create_fields([
      { name: query["name"], field_type: query["field_type"], choices: query["choices"].present?,
        choice_match: (query["choice_match"].presence if query["choices"].present?),
        depends_on: query["depends_on"].presence, parent: query["parent"].presence },
    ])
    msg = response.failed? ? "&msg=#{CGI.escape(response.message)}" : ""
    "/form?id=#{form.id}#{msg}"
  when "/add_fields"
    form = Form.find(query["form_id"])
    specs = parse_field_specs(query["specs"])
    if specs.empty?
      "/form?id=#{form.id}&msg=#{CGI.escape("no field specs")}"
    else
      response = CustomFields::FieldEditor.new(form).create_fields(specs)
      msg = response.errors.any? ? "&msg=#{CGI.escape(response.errors.map { |e| e[:message] }.join("; "))}" : ""
      "/form?id=#{form.id}#{msg}"
    end
  when "/delete_field"
    form = Form.find(query["form_id"])
    response = CustomFields::FieldEditor.new(form).delete_fields([query["name"]])
    msg = response.failed? ? "&msg=#{CGI.escape(response.message)}" : ""
    "/form?id=#{form.id}#{msg}"
  when "/delete_form"
    destroy_form(Form.find(query["form_id"]))
    "/"
  when "/set_choices", "/add_choices", "/delete_choices"
    form = Form.find(query["form_id"])
    field = latest_fields(form).find { |f| f.name == query["field"] }
    msg = ""
    if field
      editor = CustomFields::ChoiceEditor.new(form)
      values = split_values(query["values"])
      parent = query["parent"].presence
      response = case path
        when "/set_choices" then editor.set_choices(field, values)
        when "/add_choices" then editor.add_choices(field, values, parent: parent)
        when "/delete_choices" then editor.delete_choices(field, values, parent: parent)
        end
      msg = response&.failed? ? "&msg=#{CGI.escape(response.message)}" : ""
    end
    "/form?id=#{form.id}#{msg}"
  when "/create_instance"
    form = Form.find(query["form_id"])
    values = submitted_values(query, form)
    response = CustomFields::InstanceEditor.new(form).create_instance(values: values)
    if response.failed?
      "/form?id=#{form.id}&msg=#{CGI.escape(response.message)}"
    else
      "/instance?id=#{response.result.id}"
    end
  when "/update_instance"
    inst = Form::Instance.find(query["id"])
    form = inst.form
    values = submitted_values(query, form, blank_as_nil: true)
    response = CustomFields::InstanceEditor.new(form).update_instance(inst, values: values)
    if response.failed?
      "/instance?id=#{inst.id}&msg=#{CGI.escape(response.message)}"
    else
      "/instance?id=#{response.result.id}"
    end
  end
end

# ---------------------------------------------------------------- server

server = WEBrick::HTTPServer.new(Port: PORT, AccessLog: [], Logger: WEBrick::Log.new(nil, 0))

server.mount_proc "/" do |req, res|
  res["Content-Type"] = "text/html; charset=utf-8"

  if req.request_method == "POST"
    redirect = handle_post(req.path, req.query) || "/"
    res.set_redirect(WEBrick::HTTPStatus::Found, redirect)
  else
    res.body = case req.path
      when "/" then forms_index
      when "/form" then form_page(Form.find(req.query["id"]))
      when "/instance" then instance_page(Form::Instance.find(req.query["id"]))
      else page("not found", "<p>#{h req.path}</p>")
      end

    if (msg = req.query["msg"]).present?
      res.body = res.body.sub("<hr>", "<p style=\"color:#b00\">#{h msg}</p><hr>")
    end
  end
rescue WEBrick::HTTPStatus::Status
  raise
rescue ActiveRecord::RecordNotFound
  res.body = page("not found", "<p>no such record</p>")
rescue => e
  res.body = page("error", "<pre>#{h e.class}: #{h e.message}</pre><p><a href=\"/\">back</a></p>")
end

trap("INT") { server.shutdown }
puts "http://localhost:#{PORT}"
server.start
