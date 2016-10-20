module HQMF2CQL
  
  # Class containing helper methods for extracting measure attributes.
  class AttributeHelper
    
    include HQMF2CQL::Utilities
    
    NAMESPACES = HQMF2CQL::Utilities::NAMESPACES

    # Extracts the code used by a particular attribute.
    def self.handle_attribute_code(attribute, code, name)
      null_flavor = attribute.at_xpath('./cda:code/@nullFlavor', NAMESPACES).try(:value)
      o_text = attribute.at_xpath('./cda:code/cda:originalText/@value', NAMESPACES).try(:value)
      code_obj = HQMF::Coded.new(attribute.at_xpath('./cda:code/@xsi:type', NAMESPACES).try(:value) || 'CD',
                                 attribute.at_xpath('./cda:code/@codeSystem', NAMESPACES).try(:value),
                                 code,
                                 attribute.at_xpath('./cda:code/@valueSet', NAMESPACES).try(:value),
                                 name,
                                 null_flavor,
                                 o_text)
      [code_obj, null_flavor, o_text]
    end

    # Extracts the value used by a particular attribute.
    def self.handle_attribute_value(attribute, value)
      type = attribute.at_xpath('./cda:value/@xsi:type', NAMESPACES).try(:value)
      case type
      when 'II'
        if value.nil?
          value = attribute.at_xpath('./cda:value/@extension', NAMESPACES).try(:value)
        end
        HQMF::Identifier.new(type,
                             attribute.at_xpath('./cda:value/@root', NAMESPACES).try(:value),
                             attribute.at_xpath('./cda:value/@extension', NAMESPACES).try(:value))
      when 'ED'
        HQMF::ED.new(type, value, attribute.at_xpath('./cda:value/@mediaType', NAMESPACES).try(:value))
      when 'CD'
        HQMF::Coded.new('CD',
                        attribute.at_xpath('./cda:value/@codeSystem', NAMESPACES).try(:value),
                        attribute.at_xpath('./cda:value/@code', NAMESPACES).try(:value),
                        attribute.at_xpath('./cda:value/@valueSet', NAMESPACES).try(:value),
                        attribute.at_xpath('./cda:value/cda:displayName/@value', NAMESPACES).try(:value))
      else
        value.present? ? HQMF::GenericValueContainer.new(type, value) : HQMF::AnyValue.new(type)
      end
    end
    
  end
end