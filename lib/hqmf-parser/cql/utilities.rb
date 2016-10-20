module HQMF2CQL

  # Module containing parser helper functions
  module Utilities

    include HQMF1::Utilities
    include HQMF2::Utilities

    NAMESPACES = { 'cda' => 'urn:hl7-org:v3',
                   'xsi' => 'http://www.w3.org/2001/XMLSchema-instance' }

  end
end