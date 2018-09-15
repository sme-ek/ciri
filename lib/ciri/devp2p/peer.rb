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


require 'async'
require 'ciri/utils'
require 'ciri/rlp'
require_relative 'rlpx'
require_relative 'protocol_io'

module Ciri
  module DevP2P

    # represent a connected remote node
    class Peer

      class DiscoverError < StandardError
      end
      class UnknownMessageCodeError < StandardError
      end

      attr_reader :connection

      def initialize(connection, handshake, protocols)
        @connection = connection
        @handshake = handshake
        @protocols = protocols
        @protocol_io_hash = make_protocol_io_hash(protocols, handshake.caps, connection)
      end

      def to_s
        @display_name ||= begin
          Utils.to_hex(node_id.id)[0..8]
        end
      end

      def node_id
        @node_id ||= RLPX::NodeID.from_raw_id(@handshake.id)
      end

      # read and handle msg
      def start_handling(ping_interval: 15, task: Async::Task.current)
        ping_timer = task.reactor.every(ping_interval) do
          ping
        end

        message_service = task.async do
          loop do
            msg = connection.read_msg
            msg.received_at = Time.now
            handle(msg)
          end
        end

        message_service.wait
      rescue StandardError => e
        # clear up
        ping_timer.cancel
        message_service.stop if message_service&.running?
        connection.close unless connection.closed?
        # raise error
        raise
      end

      def protocol_ios
        @protocol_io_hash.values
      end

      def handle(msg)
        if msg.code == RLPX::Code::PING
          pong
        elsif msg.code == RLPX::Code::DISCOVER
          reason = RLP.decode_with_type(msg.payload, Integer)
          raise DiscoverError.new("receive error discovery message, reason: #{reason}")
        elsif msg.code == RLPX::Code::PONG
          # TODO update peer node
        else
          # send msg to sub protocol
          if (protocol_io = find_protocol_io_by_msg_code(msg.code)).nil?
            raise UnknownMessageCodeError.new("can't find protocol with msg code #{msg.code}")
          end
          protocol_io.receive_msg msg
        end
      end

      private

      BLANK_PAYLOAD = RLP.encode([]).freeze

      # response pong to message
      def ping
        connection.send_data(RLPX::Code::PING, BLANK_PAYLOAD)
      end

      # response pong to message
      def pong
        connection.send_data(RLPX::Code::PONG, BLANK_PAYLOAD)
      end

      def find_protocol_io_by_msg_code(code)
        @protocol_io_hash.values.find do |protocol_io|
          offset = protocol_io.offset
          protocol = protocol_io.protocol
          code >= offset && code < offset + protocol.length
        end
      end

      # return protocol_io_hash
      # handle multiple sub protocols upon one io
      def make_protocol_io_hash(protocols, caps, io)
        # sub protocol offset
        offset = RLPX::BASE_PROTOCOL_LENGTH
        result = {}
        # [name, version] as key
        protocols_hash = protocols.map {|protocol| [[protocol.name, protocol.version], protocol]}.to_h
        sorted_caps = caps.sort_by {|c| [c.name, c.version]}

        sorted_caps.each do |cap|
          protocol = protocols_hash[[cap.name, cap.version]]
          next unless protocol
          # ignore same name old protocols
          if (old = result[cap.name])
            result.delete(cap.name)
            offset -= old.protocol.length
          end
          result[cap.name] = ProtocolIO.new(protocol, offset, io)
          # move offset, to support next protocol
          offset += protocol.length
        end
        result
      end
    end

  end
end
