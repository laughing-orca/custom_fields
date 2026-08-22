require "custom_fields"

class Form < ActiveRecord::Base
  include CustomFields::Model::Form

  custom_fields_form field: "Form::Field",
                     instance: "Form::Instance",
                     previous_instance: "Form::PreviousInstance",
                     data_stores: ["Form::Data1", "Form::Data2"],
                     previous_data_stores: ["Form::PreviousData1", "Form::PreviousData2"],
                     choice: "Form::Choice",
                     sequence: "Form::Sequence",
                     audit: "Form::Audit",
                     max_slots_by_type: { text: 10, integer: 6, section: 2 }
end

class Form::Field < ActiveRecord::Base
  include CustomFields::Model::Field

  self.table_name = "form_fields"

  custom_fields_field form: "Form"
end

class Form::Instance < ActiveRecord::Base
  include CustomFields::Model::Instance

  self.table_name = "form_instances"

  custom_fields_instance form: "Form"
end

class Form::PreviousInstance < ActiveRecord::Base
  include CustomFields::Model::Instance

  self.table_name = "form_previous_instances"

  custom_fields_instance form: "Form"
end

class Form::Data1 < ActiveRecord::Base
  include CustomFields::Model::DataStore

  self.table_name = "form_data_1"

  custom_fields_data_store instance: "Form::Instance"
end

class Form::Data2 < ActiveRecord::Base
  include CustomFields::Model::DataStore

  self.table_name = "form_data_2"

  custom_fields_data_store instance: "Form::Instance"
end

class Form::PreviousData1 < ActiveRecord::Base
  include CustomFields::Model::DataStore

  self.table_name = "form_previous_data_1"

  custom_fields_data_store instance: "Form::PreviousInstance"
end

class Form::PreviousData2 < ActiveRecord::Base
  include CustomFields::Model::DataStore

  self.table_name = "form_previous_data_2"

  custom_fields_data_store instance: "Form::PreviousInstance"
end

class Form::Choice < ActiveRecord::Base
  include CustomFields::Model::Choice

  self.table_name = "choices"

  custom_fields_choice
end

class Form::Sequence < ActiveRecord::Base
  include CustomFields::Model::Sequence

  self.table_name = "form_sequences"

  custom_fields_sequence form: "Form"
end

class Form::Audit < ActiveRecord::Base
  include CustomFields::Model::Audit

  self.table_name = "form_audits"

  custom_fields_audit form: "Form"
end
