# frozen_string_literal: true

# Copyright (c) 2018 by Jiang Jinyang <jjyruby@gmail.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


require 'ciri/utils'

module Ciri
  module RLP

    # represent bool types: true | false
    class Bool
      ENCODED_TRUE = Ciri::Utils.big_endian_encode(0x01)
      ENCODED_FALSE = Ciri::Utils.big_endian_encode(0x80)
    end

    # represent RLP raw types, binary or array
    class Raw
    end

    # represent Bytes
    class Bytes
    end

    # represent List
    class List
    end

    # Serializable module allow ruby objects serialize/deserialize to or from RLP encoding.
    # See Ciri::RLP::Serializable::TYPES for supported type.
    #
    # schema method define ordered data structure for class, and determine how to encoding objects.
    #
    # schema follow `{attr_name: type}` format,
    # schema support simple types: Integer, RLP::Bool, RLP::Bytes, RLP::List...
    #
    # schema also support complex types: array and serializable.
    #
    # array types represented as `{attr_name: [type]}`, for example: `{bills: [Integer]}` means value of bill attr is an array of integer
    # serializable type represent value of attr is a RLP serializable object
    #
    #
    # Examples:
    #
    #   class AuthMsgV4
    #     include Ciri::RLP::Serializable
    #     include Ciri
    #
    #     # define schema
    #     schema(
    #       signature: RLP::Bytes, # raw type: string
    #       initiator_pubkey: MySerializableKey, # this attr is a RLP serializable object
    #       nonce: [Integer],
    #       version: Integer
    #     )
    #
    #     # default values
    #     default_data(version: 1)
    #   end
    #
    #   msg = AuthMsgV4.new(signature: "\x00", initiator_pubkey: my_pubkey, nonce: [1, 2, 3], version: 4)
    #   encoded = AuthMsgV4.rlp_encode(msg)
    #   msg2 = AuthMsgV4.rlp_decode(encoded)
    #   msg == msg2 # true
    #
    module Serializable
      # nil represent RLP raw value(string or array of string)
      TYPES = [Raw, Bytes, List, Integer, Bool].map {|key| [key, true]}.to_h.freeze

      # Schema specific columns types of classes, normally you should not use Serializable::Schema directly
      #
      class Schema
        include Encode
        include Decode

        class InvalidSchemaError < StandardError
        end

        # keys return data columns array
        attr_reader :keys

        KeySchema = Struct.new(:type, keyword_init: true)

        def initialize(schema)
          keys = []
          @_schema = {}

          schema.each do |key, type|
            raise InvalidSchemaError.new("incorrect type on key #{key}, #{type} is not a valid RLP class") unless check_key_type(type)
            keys << key
            @_schema[key] = KeySchema.new(type: type)
          end

          @_schema.freeze
          @keys = keys.freeze
        end

        # Get column type, see Serializable::TYPES for supported type
        def [](key)
          @_schema[key]
        end

        # Validate data, data is a Hash
        def validate!(data)
          keys.each do |key|
            raise InvalidSchemaError.new("missing key #{key}") unless data.key?(key)
          end
        end

        def rlp_encode(data, skip_keys: nil, white_list_keys: nil)
          # pre-encode, encode data to rlp compatible format(only string or array)
          used_keys = if white_list_keys
                        white_list_keys
                      elsif skip_keys
                        keys - skip_keys
                      else
                        keys
                      end
          data_list = []
          used_keys.each do |key|
            value = data[key]
            data_list << encode_with_type(value, self[key].type)
          end
          encode_list(data_list)
        end

        def rlp_decode(input)
          values = decode_list(input) do |list, stream|
            keys.each do |key|
              # decode data by type
              list << decode_with_type(stream, self[key].type)
            end
          end
          # convert to key value hash
          keys.zip(values).to_h
        end

        private

        def check_key_type(type)
          return true if TYPES.key?(type)
          return true if type.is_a?(Class) && type.respond_to?(:rlp_decode) && type.respond_to?(:rlp_encode)

          if type.is_a?(Array) && type.size == 1
            check_key_type(type[0])
          else
            false
          end
        end
      end

      module ClassMethods
        # Decode object from input
        def rlp_decode(input)
          data = schema.rlp_decode(input)
          self.new(data)
        end

        # Encode object to rlp encoding string
        def rlp_encode(item, skip_keys: nil, white_list_keys: nil)
          schema.rlp_encode(item.serializable_attributes, skip_keys: skip_keys, white_list_keys: white_list_keys)
        end

        def schema(data_schema = nil)
          if data_schema
            @data_schema = Schema.new(data_schema).tap do |schema|
              # define attributes methods
              define_attributes(schema)
            end
          else
            @data_schema ||= superclass.schema
          end
        end

        def default_data(data = nil)
          @default_data ||= data
        end

        private

        def define_attributes(schema)
          schema.keys.each do |attribute|
            module_eval <<-ATTR_METHODS
            def #{attribute}
              serializable_attributes[:"#{attribute}"]
            end

            def #{attribute}=(value)
              serializable_attributes[:"#{attribute}"] = value 
            end
            ATTR_METHODS
          end
        end
      end

      class << self
        def included(base)
          base.send :extend, ClassMethods
        end
      end

      attr_reader :serializable_attributes

      def initialize(**data)
        @serializable_attributes = (self.class.default_data || {}).merge(data)
        self.class.schema.validate!(@serializable_attributes)
      end

      def initialize_copy(orig)
        super
        @serializable_attributes = orig.serializable_attributes.dup
      end

      # Encode object to rlp encoding string
      def rlp_encode(skip_keys: nil, white_list_keys: nil)
        self.class.rlp_encode(self, skip_keys: skip_keys, white_list_keys: white_list_keys)
      end

      def ==(other)
        self.class == other.class && serializable_attributes == other.serializable_attributes
      end

    end
  end
end
