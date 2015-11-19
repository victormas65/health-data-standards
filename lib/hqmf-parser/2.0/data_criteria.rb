module HQMF2
  # Represents a data criteria specification
  class DataCriteria
    include HQMF2::Utilities

    attr_reader :property, :type, :status, :value, :effective_time, :section
    attr_reader :temporal_references, :subset_operators, :children_criteria
    attr_reader :derivation_operator, :negation, :negation_code_list_id, :description
    attr_reader :field_values, :source_data_criteria, :specific_occurrence_const
    attr_reader :specific_occurrence, :comments
    attr_reader :id, :entry, :definition, :variable, :local_variable_name

    VARIABLE_TEMPLATE = '0.1.2.3.4.5.6.7.8.9.1'
    SATISFIES_ANY_TEMPLATE = '2.16.840.1.113883.10.20.28.3.108'
    SATISFIES_ALL_TEMPLATE = '2.16.840.1.113883.10.20.28.3.109'

    CONJUNCTION_CODE_TO_DERIVATION_OP = {
      'OR' => 'UNION',
      'AND' => 'XPRODUCT'
    }

    CRITERIA_GLOB = "*[substring(name(),string-length(name())-7) = \'Criteria\']"

    # TODO: Clean up debug print statements!

    # Create a new instance based on the supplied HQMF entry
    # @param [Nokogiri::XML::Element] entry the parsed HQMF entry
    def initialize(entry, data_criteria_references = {}, occurrences_map = {})
      @entry = entry
      basic_setup
      @do_not_group = false
      @template_ids = extract_template_ids
      @data_criteria_references = data_criteria_references
      @occurrences_map = occurrences_map
      @local_variable_name = extract_local_variable_name
      @description = extract_description
      handle_variable_subsets
      extract_negation
      extract_specific_or_source
      @temporal_references = extract_temporal_references
      @derivation_operator = extract_derivation_operator
      @field_values = extract_field_values
      @children_criteria = extract_child_criteria
      @variable = extract_variable
      @subset_operators = extract_subset_operators
      # Try to determine what kind of data criteria we are dealing with
      # First we look for a template id and if we find one just use the definition
      # status and negation associated with that
      # If no template id or not one we recognize then try to determine type from
      # the definition element
      extract_type_from_definition unless extract_type_from_template_id

      post_processing
    end

    def basic_setup
      @status = attr_val('./*/cda:statusCode/@code')
      @id_xpath = './*/cda:id/@extension'
      @id = "#{attr_val('./*/cda:id/@extension')}_#{attr_val('./*/cda:id/@root')}"
      @comments = @entry.xpath("./#{CRITERIA_GLOB}/cda:text/cda:xml/cda:qdmUserComments/cda:item/text()", HQMF2::Document::NAMESPACES).map(&:content)
      @code_list_xpath = './*/cda:code'
      @value_xpath = './*/cda:value'
    end

    # Handles settings values after (most) values have been setup
    def post_processing
      set_code_list_path_and_result_value

      # prefix ids that start with numerical values, and strip tokens from others
      @id = strip_tokens @id
      @children_criteria.map! { |cc| strip_tokens cc }

      #### prefix!!!!!!!!!

      @source_data_criteria = strip_tokens(@source_data_criteria) unless @source_data_criteria.nil?
      @specific_occurrence_const = strip_tokens(@specific_occurrence_const) unless @specific_occurrence_const.nil?
      set_intersection
      handle_specific_variables
    end

    def handle_variable_subsets
      is_grouper = @entry.at_xpath('./cda:grouperCriteria')
      references = @entry.xpath('./*/cda:outboundRelationship/cda:criteriaReference', HQMF2::Document::NAMESPACES)
      reference = references.first
      # Variables should now always handled as verbose
      return unless references.try(:length) == 1
      ref_id = strip_tokens("#{HQMF2::Utilities.attr_val(reference, 'cda:id/@extension')}_#{HQMF2::Utilities.attr_val(reference, 'cda:id/@root')}")
      reference_criteria = @data_criteria_references[ref_id] if ref_id
      return if is_grouper.nil? || !reference_criteria.try(:variable)
      id_extension_xpath = './*/cda:id/@extension'
      return unless (attr_val(id_extension_xpath) =~ /^occ[A-Z]of_qdm_var_/).nil?
      @verbose_reference = true
    end

    def set_code_list_path_and_result_value
      if @template_ids.empty? && @specific_occurrence
        template = @entry.document.at_xpath(
          "//cda:id[@root='#{@source_data_criteria_root}' and @extension='#{@source_data_criteria_extension}']/../cda:templateId/cda:item/@root")
        if template
          mapping = ValueSetHelper.get_mapping_for_template(template.to_s)
          handle_mapping_template(mapping)
        end
      end
      @template_ids.each do |t|
        mapping = ValueSetHelper.get_mapping_for_template(t)
        handle_mapping_template(mapping)
      end
    end

    def handle_mapping_template(mapping)
      if mapping
        @code_list_xpath = mapping[:valueset_path] if mapping[:valueset_path] && @entry.at_xpath(mapping[:valueset_path])
        @value = DataCriteria.parse_value(@entry, mapping[:result_path]) if mapping[:result_path]
      end
    end

    def extract_local_variable_name
      lvn = @entry.at_xpath('./cda:localVariableName')
      lvn['value'] if lvn
    end

    def extract_type_from_definition
      # if we have a specific occurrence of a variable, pull attributes from the reference
      extract_type_from_specific_variable if @variable && @specific_occurrence

      if @entry.at_xpath('./cda:grouperCriteria')
        @definition ||= 'derived'
        return
      end
      # See if we can find a match for the entry definition value and status.
      entry_type = attr_val('./*/cda:definition/*/cda:id/@extension')
      handle_entry_type(entry_type)
    end

    def handle_entry_type(entry_type)
      # settings is required to trigger exceptions, which set the definition
      HQMF::DataCriteria.get_settings_for_definition(entry_type, @status)
      @definition = entry_type
    rescue
      # if no exact match then try a string match just using entry definition value
      case entry_type
      when 'Medication', 'Medications'
        @definition = 'medication'
        @status = 'active' unless @status
      when 'RX'
        @definition = 'medication'
        @status = 'dispensed' unless @status
      when nil
        definition_for_nil_entry
      else
        @definition = DataCriteriaMethods.extract_definition_from_entry_type(entry_type)
      end
    end

    def extract_type_from_specific_variable
      reference = @entry.at_xpath('./*/cda:outboundRelationship/cda:criteriaReference', HQMF2::Document::NAMESPACES)
      if reference
        ref_id = strip_tokens(
          "#{HQMF2::Utilities.attr_val(reference, 'cda:id/@extension')}_#{HQMF2::Utilities.attr_val(reference, 'cda:id/@root')}")
      end
      reference_criteria = @data_criteria_references[ref_id] if ref_id
      # if the reference is derived, pull from the original variable
      reference_criteria = @data_criteria_references["GROUP_#{ref_id}"] if reference_criteria && reference_criteria.definition == 'derived'
      return unless reference_criteria
      handle_specific_variable_ref(reference_criteria)
    end

    def handle_specific_variable_ref(reference_criteria)
      # if there are no referenced children, then it's a variable representing
      # a single data criteria, so just reference it
      if reference_criteria.children_criteria.empty?
        @children_criteria = [reference_criteria.id]
      # otherwise pull all the data criteria info from the reference
      else
        @field_values = reference_criteria.field_values
        @temporal_references = reference_criteria.temporal_references
        @subset_operators = reference_criteria.subset_operators
        @derivation_operator = reference_criteria.derivation_operator
        @definition = reference_criteria.definition
        @description = reference_criteria.description
        @status = reference_criteria.status
        @children_criteria = reference_criteria.children_criteria
      end
    end

    def definition_for_nil_entry
      reference = @entry.at_xpath('./*/cda:outboundRelationship/cda:criteriaReference', HQMF2::Document::NAMESPACES)
      ref_id = nil
      unless reference.nil?
        ref_id = "#{HQMF2::Utilities.attr_val(reference, 'cda:id/@extension')}_#{HQMF2::Utilities.attr_val(reference, 'cda:id/@root')}"
      end
      reference_criteria = @data_criteria_references[strip_tokens(ref_id)] unless ref_id.nil?
      if reference_criteria
        @definition = reference_criteria.definition
        @status = reference_criteria.status
        if @specific_occurrence
          @title = reference_criteria.title
          @description = reference_criteria.description
          @code_list_id = reference_criteria.code_list_id
        end
      else
        puts "MISSING_DC_REF: #{ref_id}" unless @variable
        @definition = 'variable'
      end
    end

    def extract_type_from_template_id
      found = false

      @template_ids.each do |template_id|
        defs = HQMF::DataCriteria.definition_for_template_id(template_id, 'r2')
        if defs
          @definition = defs['definition']
          @status = defs['status'].length > 0 ? defs['status'] : nil
          found ||= true
        else
          found ||= extract_type_from_known_template_id(template_id)
        end
      end

      found
    end

    def extract_type_from_known_template_id(template_id)
      case template_id
      when VARIABLE_TEMPLATE
        @derivation_operator = HQMF::DataCriteria::INTERSECT if @derivation_operator == HQMF::DataCriteria::XPRODUCT
        @definition ||= 'derived'
        @variable = true
        @negation = false
      when SATISFIES_ANY_TEMPLATE
        @definition = HQMF::DataCriteria::SATISFIES_ANY
        @negation = false
      when SATISFIES_ALL_TEMPLATE
        @definition = HQMF::DataCriteria::SATISFIES_ALL
        @derivation_operator = HQMF::DataCriteria::INTERSECT
        @negation = false
      else
        return false
      end
      true
    end

    def set_intersection
      # Need to handle grouper criteria that do not have template ids -- these will be union of and intersection criteria
      return unless @template_ids.empty?
      # Change the XPRODUCT to an INTERSECT otherwise leave it as a UNION
      @derivation_operator = HQMF::DataCriteria::INTERSECT if @derivation_operator == HQMF::DataCriteria::XPRODUCT
      @description ||= (@derivation_operator == HQMF::DataCriteria::INTERSECT) ? 'Intersect' : 'Union'
    end

    def to_s
      props = {
        property: property,
        type: type,
        status: status,
        section: section
      }
      "DataCriteria#{props}"
    end

    # TODO: Remove id method if id attribute is sufficient
    # Get the identifier of the criteria, used elsewhere within the document for referencing
    # @return [String] the identifier of this data criteria
    # def id
    #   attr_val(@id_xpath)
    # end

    # Get the title of the criteria, provides a human readable description
    # @return [String] the title of this data criteria
    def title
      disp_value = attr_val("#{@code_list_xpath}/cda:displayName/@value")
      @title || disp_value || @description || id # allow defined titles to take precedence
    end

    # Get the code list OID of the criteria, used as an index to the code list database
    # @return [String] the code list identifier of this data criteria
    def code_list_id
      @code_list_id || attr_val("#{@code_list_xpath}/@valueSet")
    end

    def inline_code_list
      code_system = attr_val("#{@code_list_xpath}/@codeSystem")
      if code_system
        code_system_name = HealthDataStandards::Util::CodeSystemHelper.code_system_for(code_system)
      else
        code_system_name = attr_val("#{@code_list_xpath}/@codeSystemName")
      end
      code_value = attr_val("#{@code_list_xpath}/@code")
      { code_system_name => [code_value] } if code_system_name && code_value
    end

    def to_model
      mv = value.try(:to_model)
      met = effective_time.try(:to_model)
      mtr = temporal_references.collect(&:to_model)
      mso = subset_operators.collect(&:to_model)
      field_values = model_field_values

      handle_title_and_description unless @variable || @derivation_operator

      @code_list_id = nil if @derivation_operator

      # prevent json model generation of empty children and comments
      cc = children_criteria.present? ? children_criteria : nil
      comments = @comments.present? ? @comments : nil

      HQMF::DataCriteria.new(id, title, nil, description, @code_list_id, cc,
                             derivation_operator, @definition, status, mv, field_values, met, inline_code_list,
                             @negation, @negation_code_list_id, mtr, mso, @specific_occurrence,
                             @specific_occurrence_const, @source_data_criteria, comments, @variable)
    end

    def model_field_values
      field_values = {}
      @field_values.each_pair do |id, val|
        field_values[id] = val.to_model
      end
      @code_list_id ||= code_list_id

      # Model transfers as a field
      if %w(transfer_to transfer_from).include? @definition
        field_values ||= {}
        field_code_list_id = @code_list_id
        @code_list_id = nil
        unless field_code_list_id
          field_code_list_id = attr_val("./#{CRITERIA_GLOB}/cda:outboundRelationship/#{CRITERIA_GLOB}/cda:value/@valueSet")
        end
        field_values[@definition.upcase] = HQMF::Coded.for_code_list(field_code_list_id, title)
      end

      return field_values unless field_values.empty?
    end

    def handle_title_and_description
      # drop "* Value Set" from titles
      exact_desc = title.split(' ')[0...-3].join(' ')
      # don't drop anything for patient characterstic titles
      exact_desc = title if @definition.start_with?('patient_characteristic') && !title.end_with?('Value Set')

      # remove * Value Set from title
      title_match = title.match(/(.*) \w+ [Vv]alue [Ss]et/)
      @title = title_match[1] if title_match && title_match.length > 1

      @description = "#{@description}: #{exact_desc}"
    end

    # Return a new DataCriteria instance with only grouper attributes set
    def extract_variable_grouper
      return unless @variable
      if @do_not_group
        handle_do_not_group
        return
      end
      @variable = false
      @id = "GROUP_#{@id}"
      if @children_criteria.length == 1 && @children_criteria[0] =~ /GROUP_/
        reference_criteria = @data_criteria_references[@children_criteria.first]
        return if reference_criteria.nil?
        duplicate_child_info(reference_criteria)
        @definition = reference_criteria.definition
        @status = reference_criteria.status
        @children_criteria = []
      end
      @specific_occurrence = nil
      @specific_occurrence_const = nil
      DataCriteria.new(@entry, @data_criteria_references, @occurrences_map).extract_as_grouper
    end

    def handle_do_not_group
      if !@data_criteria_references["GROUP_#{@children_criteria.first}"].nil? && @children_criteria.length == 1
        @children_criteria[0] = "GROUP_#{@children_criteria.first}"
      elsif @children_criteria.length == 1 && @children_criteria.first.present?
        reference_criteria = @data_criteria_references[@children_criteria.first]
        return if reference_criteria.nil?
        duplicate_child_info(reference_criteria)
        @children_criteria = reference_criteria.children_criteria
      end
    end

    def duplicate_child_info(child_ref)
      @title ||= child_ref.title
      @type ||= child_ref.subset_operators
      @definition ||= child_ref.definition
      @status ||= child_ref.status
      @code_list_id ||= child_ref.code_list_id
      @temporal_references = child_ref.temporal_references if @temporal_references.empty?
      @subset_operators ||= child_ref.subset_operators
      @variable ||= child_ref.variable
      @value ||= child_ref.value
    end

    # Set this data criteria's attributes for extraction as a grouper data criteria
    # for encapsulating a variable data criteria
    # SHOULD only be called on the variable data criteria instance
    def extract_as_grouper
      @field_values = {}
      @temporal_references = []
      @subset_operators = []
      @derivation_operator = HQMF::DataCriteria::UNION
      @definition = 'derived'
      @status = nil
      @children_criteria = ["GROUP_#{@id}"]
      @source_data_criteria = @id
      self
    end

    private

    def extract_negation
      negation = attr_val('./*/@actionNegationInd')
      @negation = (negation == 'true')
      if @negation
        res = @entry.at_xpath('./*/cda:outboundRelationship/*/cda:code[@code="410666004"]/../cda:value/@valueSet', HQMF2::Document::NAMESPACES)
        @negation_code_list_id = res.value if res
      else
        @negation_code_list_id = nil
      end
    end

    def extract_child_criteria
      @entry.xpath("./*/cda:outboundRelationship[@typeCode='COMP']/cda:criteriaReference/cda:id", HQMF2::Document::NAMESPACES).collect do |ref|
        Reference.new(ref).id
      end.compact
    end

    def all_subset_operators
      @entry.xpath('./*/cda:excerpt', HQMF2::Document::NAMESPACES).collect do |subset_operator|
        SubsetOperator.new(subset_operator)
      end
    end

    def extract_derivation_operator
      codes = @entry.xpath("./*/cda:outboundRelationship[@typeCode='COMP']/cda:conjunctionCode/@code", HQMF2::Document::NAMESPACES)
      codes.inject(nil) do |d_op, code|
        fail 'More than one derivation operator in data criteria' if d_op && d_op != CONJUNCTION_CODE_TO_DERIVATION_OP[code.value]
        CONJUNCTION_CODE_TO_DERIVATION_OP[code.value]
      end
    end

    def extract_subset_operators
      all_subset_operators.select do |operator|
        operator.type != 'UNION' && operator.type != 'XPRODUCT'
      end
    end

    def extract_specific_or_source
      specific_def = @entry.at_xpath('./*/cda:outboundRelationship[@typeCode="OCCR"]', HQMF2::Document::NAMESPACES)
      source_def = @entry.at_xpath('./*/cda:outboundRelationship[cda:subsetCode/@code="SOURCE"]', HQMF2::Document::NAMESPACES)
      if specific_def
        @source_data_criteria_extension = HQMF2::Utilities.attr_val(specific_def, './cda:criteriaReference/cda:id/@extension')
        @source_data_criteria_root = HQMF2::Utilities.attr_val(specific_def, './cda:criteriaReference/cda:id/@root')

        occurrence_criteria = @data_criteria_references[strip_tokens "#{@source_data_criteria_extension}_#{@source_data_criteria_root}"]

        return if occurrence_criteria.nil?
        @specific_occurrence_const = HQMF2::Utilities.attr_val(specific_def, './cda:localVariableName/@controlInformationRoot')
        @specific_occurrence = HQMF2::Utilities.attr_val(specific_def, './cda:localVariableName/@controlInformationExtension')
        is_variable = extract_variable

        # FIXME: Remove debug statements after cleaning up occurrence handling
        # build regex for extracting alpha-index of specific occurrences
        occurrence_identifier = DataCriteriaMethods.obtain_occurrence_identifier(strip_tokens(@id),
                                                                                 strip_tokens(@local_variable_name) || '',
                                                                                 strip_tokens(@source_data_criteria_extension),
                                                                                 is_variable)

        handle_specific_and_source(occurrence_identifier, is_variable)

      elsif source_def
        extension = HQMF2::Utilities.attr_val(source_def, './cda:criteriaReference/cda:id/@extension')
        root = HQMF2::Utilities.attr_val(source_def, './cda:criteriaReference/cda:id/@root')
        @source_data_criteria = "#{extension}_#{root}"
      end
    end

    # Handle setting the specific and source instance variables with a given occurrence identifier
    def handle_specific_and_source(occurrence_identifier, is_variable)
      @source_data_criteria = "#{@source_data_criteria_extension}_#{@source_data_criteria_root}"
      if !occurrence_identifier.blank?
        # if it doesn't exist, add extracted occurrence to the map
        # puts "\tSetting #{@source_data_criteria}-#{@source_data_criteria_root} to #{occurrence_identifier}"
        @occurrences_map[@source_data_criteria] ||= occurrence_identifier
        @specific_occurrence ||= occurrence_identifier
        @specific_occurrence_const = "#{@source_data_criteria}".upcase
      else
        # create variable occurrences that do not already exist
        if is_variable
          # puts "\tSetting #{@source_data_criteria}-#{@source_data_criteria_root} to #{occurrence_identifier}"
          @occurrences_map[@source_data_criteria] ||= occurrence_identifier
        end
        occurrence = @occurrences_map.try(:[], @source_data_criteria)
        fail "Could not find occurrence mapping for #{@source_data_criteria}, #{@source_data_criteria_root}" unless occurrence
        # puts "\tUsing #{occurrence} for #{@id}"
        @specific_occurrence ||= occurrence
      end

      @specific_occurrence = 'A' unless @specific_occurrence
      @specific_occurrence_const = @source_data_criteria.upcase unless @specific_occurrence_const
    end

    def handle_specific_variables
      return unless @definition == 'derived'
      # Adds a child if none exists (specifically the source criteria)
      @children_criteria << @source_data_criteria if @children_criteria.empty?
      return if @children_criteria.length != 1 || (@source_data_criteria.present? && @children_criteria.first != @source_data_criteria)
      # if child.first is nil, it will be caught in the second statement
      reference_criteria = @data_criteria_references[@children_criteria.first]
      return if reference_criteria.nil?
      @do_not_group = true # easier to track than all testing all features of these cases
      @subset_operators ||= reference_criteria.subset_operators
      @derivation_operator ||= reference_criteria.derivation_operator
      @description = reference_criteria.description
      @variable = reference_criteria.variable
    end

    def extract_field_values
      fields = {}
      # extract most fields which use the same structure
      @entry.xpath('./*/cda:outboundRelationship[*/cda:code]', HQMF2::Document::NAMESPACES).each do |field|
        code = HQMF2::Utilities.attr_val(field, './*/cda:code/@code')
        code_id = HQMF::DataCriteria::VALUE_FIELDS[code]
        # No need to run if there is no code id
        next if (@negation && code_id == 'REASON') || code_id.nil?
        value = DataCriteria.parse_value(field, './*/cda:value')
        value ||= DataCriteria.parse_value(field, './*/cda:effectiveTime')
        fields[code_id] = value
      end
      # special case for facility location which uses a very different structure
      @entry.xpath('./*/cda:outboundRelationship[*/cda:participation]', HQMF2::Document::NAMESPACES).each do |field|
        code = HQMF2::Utilities.attr_val(field, './*/cda:participation/cda:role/@classCode')
        code_id = HQMF::DataCriteria::VALUE_FIELDS[code]
        next if code_id.nil?
        value = Coded.new(field.at_xpath('./*/cda:participation/cda:role/cda:code', HQMF2::Document::NAMESPACES))
        fields[code_id] = value
      end

      fields.merge! HQMF2::FieldValueHelper.parse_field_values(@entry, @negation)
      # special case for fulfills operator.  assuming there is only a possibility of having one of these
      fulfills = @entry.at_xpath('./*/cda:outboundRelationship[@typeCode="FLFS"]/cda:criteriaReference', HQMF2::Document::NAMESPACES)
      # grab the child element if we don't have a reference
      fields['FLFS'] = TypedReference.new(fulfills) if fulfills
      fields
    end

    def extract_temporal_references
      @entry.xpath('./*/cda:temporallyRelatedInformation', HQMF2::Document::NAMESPACES).collect do |temporal_reference|
        TemporalReference.new(temporal_reference)
      end
    end

    def extract_value
      # need to look in both places for result criteria because
      # procedureCriteria does not have a value element while observationCriteria does
      DataCriteria.parse_value(@entry, './*/cda:value') ||
        DataCriteria.parse_value(@entry, "./*/cda:outboundRelationship/cda:code[@code='394617004']/../cda:value")
    end

    def self.parse_value(node, xpath)
      value_def = node.at_xpath(xpath, HQMF2::Document::NAMESPACES)
      if value_def
        return AnyValue.new if value_def.at_xpath('@flavorId') == 'ANY.NONNULL'
        value_type_def = value_def.at_xpath('@xsi:type', HQMF2::Document::NAMESPACES)
        return handle_value_type(value_type_def, value_def) if value_type_def
      end
    end

    def self.handle_value_type(value_type_def, value_def)
      value_type = value_type_def.value
      case value_type
      when 'PQ'
        Value.new(value_def, 'PQ', true)
      when 'TS'
        Value.new(value_def)
      when 'IVL_PQ', 'IVL_INT'
        Range.new(value_def)
      when 'CD'
        Coded.new(value_def)
      when 'ANY', 'IVL_TS'
        # FIXME: (10/26/2015) IVL_TS should be able to handle other values, not just AnyValue
        AnyValue.new
      else
        fail "Unknown value type [#{value_type}]"
      end
    end

    # Extract the description, with some special handling if this is a variable; the MAT has added an encoded
    # form of the variable name in the localVariableName field, if that's available use it; if not, fall back
    # to the extension
    def extract_description
      if extract_variable
        encoded_name = attr_val('./cda:localVariableName/@value')
        encoded_name = DataCriteriaMethods.extract_description_for_variable(encoded_name) if encoded_name
        return encoded_name if encoded_name.present?
        attr_val("./#{CRITERIA_GLOB}/cda:id/@extension")
      else
        attr_val("./#{CRITERIA_GLOB}/cda:text/@value") ||
          attr_val("./#{CRITERIA_GLOB}/cda:title/@value") ||
          attr_val("./#{CRITERIA_GLOB}/cda:id/@extension")
      end
    end

    # Determine if this instance is a qdm variable
    def extract_variable
      variable = !(@local_variable_name =~ /.*qdm_var_/).nil? unless @local_variable_name.blank?
      variable ||= !(@id =~ /.*qdm_var_/).nil? unless @id.blank?
      variable
    end

    def extract_template_ids
      @entry.xpath('./*/cda:templateId/cda:item', HQMF2::Document::NAMESPACES).collect do |template_def|
        HQMF2::Utilities.attr_val(template_def, '@root')
      end
    end
  end

  # Handles various tasks that the Data Criteria needs performed to obtain and
  # modify secific occurrences
  class SpecificOccurrence
  end

  # Handles performance of methods not tied to the data criteria's instance vairables
  class DataCriteriaMethods
    def self.extract_definition_from_entry_type(entry_type)
      case entry_type
      when 'Problem', 'Problems'
        'diagnosis'
      when 'Encounter', 'Encounters'
        'encounter'
      when 'LabResults', 'Results'
        'laboratory_test'
      when 'Procedure', 'Procedures'
        'procedure'
      when 'Demographics'
        definition_for_demographic
      when 'Derived'
        'derived'
      else
        fail "Unknown data criteria template identifier [#{entry_type}]"
      end
    end

    def self.obtain_occurrence_identifier(stripped_id, stripped_lvn, stripped_sdc, is_variable)
      if is_variable
        occurrence_lvn_regex = 'occ[A-Z]of_'
        occurrence_id_regex = 'occ[A-Z]of_'
        occ_index = 3
        return handle_occurrence_var(stripped_id, stripped_lvn, occurrence_id_regex, occurrence_lvn_regex, occ_index)
      else
        occurrence_lvn_regex = 'Occurrence[A-Z]of'
        occurrence_id_regex = 'Occurrence[A-Z]_'
        occ_index = 10
      end
      # TODO: What should happen is neither @id or @lvn has occurrence label?
      # puts "Checking #{"#{occurrence_id_regex}#{stripped_sdc}"} against #{stripped_id}"
      # puts "Checking #{"#{occurrence_lvn_regex}#{stripped_sdc}"} against #{stripped_lvn}"
      if stripped_id.match(/^#{occurrence_id_regex}#{stripped_sdc}/)
        return stripped_id[occ_index]
      elsif stripped_lvn.match(/^#{occurrence_lvn_regex}#{stripped_sdc}/)
        return stripped_lvn[occ_index]
      end

      stripped_sdc[occ_index] if stripped_sdc.match(
        /(^#{occurrence_id_regex}| ^#{occurrence_id_regex}qdm_var_| ^#{occurrence_lvn_regex})| ^#{occurrence_lvn_regex}qdm_var_/)
    end

    def self.handle_occurrence_var(stripped_id, stripped_lvn, occurrence_id_regex, occurrence_lvn_regex, occ_index)
      # TODO: Handle specific occurrences of variables that don't self-reference?
      if stripped_id.match(/^#{occurrence_id_regex}qdm_var_/)
        return stripped_id[occ_index]
      elsif stripped_lvn.match(/^#{occurrence_lvn_regex}qdm_var/)
        return stripped_lvn[occ_index]
      end
    end

    # Return the definitino for a known subset of patient characteristics
    def self.definition_for_demographic
      demographic_type = attr_val('./cda:observationCriteria/cda:code/@code')
      demographic_translation = {
        '21112-8' => 'patient_characteristic_birthdate',
        '424144002' => 'patient_characteristic_age',
        '263495000' => 'patient_characteristic_gender',
        '102902016' => 'patient_characteristic_languages',
        '125680007' => 'patient_characteristic_marital_status',
        '103579009' => 'patient_characteristic_race'
      }
      if demographic_translation[demographic_type]
        demographic_translation[demographic_type]
      else
        fail "Unknown demographic identifier [#{demographic_type}]"
      end
    end

    def self.extract_description_for_variable(encoded_name)
      if encoded_name.match(/^qdm_var_/)
        # Strip out initial qdm_var_ string, trailing _*, and possible occurrence reference
        encoded_name.gsub!(/^qdm_var_|/, '')
        encoded_name.gsub!(/Occurrence[A-Z]of/, '')
        # This code needs to handle measures created before the MAT added variable name hints; for those, don't strip the final identifier
        unless encoded_name.match(/^(SATISFIES ALL|SATISFIES ANY|UNION|INTERSECTION)/)
          encoded_name.gsub!(/_[^_]+$/, '')
        end
        encoded_name
      elsif encoded_name.match(/^localVar_/)
        encoded_name.gsub!(/^localVar_/, '')
        encoded_name
      end
    end
  end
end
