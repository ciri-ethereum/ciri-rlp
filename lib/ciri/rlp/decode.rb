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


require 'stringio'
require 'ciri/utils/logger'

module Ciri
  module RLP
    module Decode
      include Utils::Logger

      # Decode input from rlp encoding, only produce string or array
      #
      # Examples:
      #
      #   Ciri::RLP.decode(input)
      #
      def decode(input, type = Raw)
        decode_with_type(input, type)
      end

      # Use this method after RLP.decode, decode values from string or array to specific types
      # see Ciri::RLP::Serializable::TYPES for supported types
      #
      # Examples:
      #
      #   item = Ciri::RLP.decode(encoded_text)
      #   decode_with_type(item, Integer)
      #
      def decode_with_type(s, type)
        s = StringIO.new(s) if s.is_a?(String)
        if type == Integer
          item = s.read(1)
          if item.nil?
            raise InvalidError.new "invalid Integer value nil"
          elsif item == "\x80".b || item.empty?
            0
          elsif item.ord < 0x80
            item.ord
          else
            size = item[0].ord - 0x80
            Ciri::Utils.big_endian_decode(s.read(size))
          end
        elsif type == Bool
          item = s.read(1)
          if item == Bool::ENCODED_TRUE
            true
          elsif item == Bool::ENCODED_FALSE
            false
          else
            raise InvalidError.new "invalid bool value #{item}"
          end
        elsif type.is_a?(Class) && type.respond_to?(:rlp_decode)
          type.rlp_decode(s)
        elsif type.is_a?(Array)
          decode_list(s) do |list, s2|
            i = 0
            until s2.eof?
              t = type.size > i ? type[i] : type[-1]
              list << decode_with_type(s2, t)
              i += 1
            end
          end
        elsif type == Bytes
          str = decode_stream(s)
          raise RLP::InvalidError.new "decode #{str.class} from Bytes" unless str.is_a?(String)
          str
        elsif type == List
          list = decode_stream(s)
          raise RLP::InvalidError.new "decode #{list.class} from List" unless list.is_a?(Array)
          list
        elsif type == Raw
          decode_stream(s)
        else
          raise RLP::InvalidError.new "unknown type #{type}"
        end
      rescue
        error "when decoding #{s} into #{type}"
        raise
      end

      protected

      def decode_list(s, first_char = nil, &decoder)
        s = StringIO.new(s) if s.is_a?(String)
        c = first_char || s.read(1)
        list = []
        # list is empty
        # return list if c.nil?
        sub_s = case c.ord
                when 0xc0..0xf7
                  length = c.ord - 0xc0
                  s.read(length)
                when 0xf8..0xff
                  length_binary = s.read(c.ord - 0xf7)
                  length = int_from_binary(length_binary)
                  check_range_and_read(s, length)
                else
                  raise InvalidError.new("invalid char #{c}")
                end

        raise InvalidError.new("stream EOF when encode_list") unless sub_s

        decoder.call(list, StringIO.new(sub_s))
        list
      end

      private

      def decode_stream(s)
        c = s.read(1)
        raise InvalidError.new("read none char from stream") unless c
        case c.ord
        when 0x00..0x7f
          c
        when 0x80..0xb7
          length = c.ord - 0x80
          s.read(length)
        when 0xb8..0xbf
          length_binary = s.read(c.ord - 0xb7)
          length = int_from_binary(length_binary)
          check_range_and_read(s, length)
        else
          decode_list(s, c) do |list, s2|
            until s2.eof?
              list << decode_stream(s2)
            end
          end
        end
      end

      def check_range_and_read(s, length)
        s.read(length)
      rescue RangeError
        raise InvalidError.new("length too long: #{length}")
      end

      def int_from_binary(input)
        Ciri::Utils.big_endian_decode(input)
      end

    end
  end
end
