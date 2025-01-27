// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package io.opentelemetry.render.generator

import org.eclipse.xtext.generator.IFileSystemAccess2

import io.opentelemetry.render.render.App
import static io.opentelemetry.render.generator.AppGenerator.outputPath
import static io.opentelemetry.render.generator.RenderGenerator.generatedCodeWarning
import static extension io.opentelemetry.render.extensions.AppExtensions.*
import static extension io.opentelemetry.render.extensions.MessageExtensions.*

class ProtocolGenerator {

  def void doGenerate(App app, IFileSystemAccess2 fsa) {
    fsa.generateFile(outputPath(app, "protocol.h"), generateProtocolH(app))
    fsa.generateFile(outputPath(app, "protocol.cc"), generateProtocolCc(app))
  }

  private static def generateProtocolH(App app) {
    '''
    «generatedCodeWarning()»
    #pragma once

    #include "hash.h"

    #include <jitbuf/perfect_hash.h>
    «IF app.jit»
      #include <jitbuf/transform_builder.h>
    «ENDIF»
    #include <platform/types.h>

    #include <chrono>

    namespace «app.pkg.name»::«app.name» {

    /* forward declaration */
    class TransformBuilder;

    /******************************************************************************
     * PROTOCOL CLASS: handles messages for a single connection
     ******************************************************************************/
    class Protocol {
    public:
      /* message format transform function type */
      typedef uint16_t (*transform)(const char *src, char *dst);

      /* handler function type */
      typedef void (*handler_func_t)(void *context, u64 timestamp, char *msg_buf);

      /**
       * C'tor
       */
      Protocol(TransformBuilder &builder);

      struct handle_result_t {
        int result;
        std::chrono::nanoseconds client_timestamp;
      };

      /**
       * handle a message
       * @returns: the client's timestamp, as well as:
       *   the message length on success or an error code,
       *   -ENOENT if message was not added
       *   -EACCES if message was not authenticated
       *   -EAGAIN if buffer is too small
       *   note that handler function might throw.
       */
      handle_result_t handle(const char *msg, uint32_t len);

      /**
       * Handles multiple consecutive messages
       * @returns: the client's timestamp, as well as:
       *    the length of successfully consumed messages if at least one
       *    message was processed, otherwise like handle()
       */
      handle_result_t handle_multiple(const char *msg, u64 len);

      /**
       * Adds a handler function for the given RPC.
       *
       * @param rpc_id: the RPC's ID
       * @param context: the context the handler is called on
       * @param handler_fn: the handler
       */
      void add_handler(u16 rpc_id, void *context, handler_func_t handler_fn);

      «IF app.jit»
        /**
         * inserts the transform for the given RPC
         */
        void insert_transform(u16 rpc_id, transform xform, u32 size,
            std::shared_ptr<jitbuf::TransformRecord> &transform_ptr);
      «ENDIF»

      /**
       * insert an identity transform for the given RPC ID
       */
      void insert_identity_transform(u16 rpc_id);

      /**
       * inserts default identity transforms for no-auth messages
       */
      void insert_no_auth_identity_transforms();

      /**
       * inserts default identity transforms for need-auth messages
       */
      void insert_need_auth_identity_transforms();

    private:
      TransformBuilder &builder_;

      /* information about our implemented messages */
      struct func_info {
        void *context;
        handler_func_t handler_fn;
      };
      PerfectHash<func_info, «app.hashSize», «app.hashFunctor»> funcs_;

      /* information about handlers and transforms for processing messages */
      struct handler_info {
        transform xform;
        void *context;
        handler_func_t handler_fn;
        u32 size;
        «IF app.jit»
          std::shared_ptr<jitbuf::TransformRecord> transform_ptr;
        «ENDIF»
      };
      PerfectHash<handler_info, «app.hashSize», «app.hashFunctor»> handlers_;
    };

    } // namespace «app.pkg.name»::«app.name»
    '''
  }

  private static def generateProtocolCc(App app) {
    val messages = app.messages

    /* compute an upper bound on parsed message size */
    val max_message_size =
      if (messages.size == 0)
        0
      else
        messages.map[parsed_msg.size].max

    val need_auth_msg = messages.filter[!noAuthorizationNeeded];

    '''
    «generatedCodeWarning()»

    #include "protocol.h"
    #include "transform_builder.h"
    #include "parsed_message.h"
    #include "wire_message.h"

    #include <algorithm>
    #include <iostream>
    #include <stdexcept>
    #include <string>

    namespace «app.pkg.name»::«app.name» {

    /******************************************************************************
     * PROTOCOL CLASS: C'tor
     ******************************************************************************/
    Protocol::Protocol(TransformBuilder &builder)
      : builder_(builder)
    {}


    /******************************************************************************
     * PROTOCOL CLASS: incoming buffer handler
     ******************************************************************************/
    Protocol::handle_result_t Protocol::handle(const char *msg, uint32_t len)
    {
      «IF app.spans.size == 0»
        /* no spans */
        return {.result = -EINVAL, .client_timestamp = std::chrono::nanoseconds::zero()};
      «ELSE»
        /* size check: should have enough for timestamp and rpc_id */
        if (len < sizeof(u64) + sizeof(u16)) {
          /* not enough data to read headers */
          return {.result = -EAGAIN, .client_timestamp = std::chrono::nanoseconds::zero()};
        }

        /* Handle timestamps */
        std::chrono::nanoseconds remote_timestamp{*(u64 const *)msg};

        msg += sizeof(u64);
        len -= sizeof(u64);

        /* get RPC ID */
        uint16_t rpc_id = *(uint16_t *)msg;

        /* find handler for RPC ID */
        handler_info *record = handlers_.find(rpc_id);

        if (record == nullptr) {
          // compile-time list of rpc ids that need authentication
          constexpr std::size_t need_auth_rpc_ids_count = «need_auth_msg.length»;
          constexpr u16 need_auth_rpc_ids[] = {«FOR rpc_id : need_auth_msg.map[wire_msg].map[rpc_id].sort SEPARATOR ", "»«rpc_id»«ENDFOR»};

          if (std::binary_search(need_auth_rpc_ids, need_auth_rpc_ids + need_auth_rpc_ids_count, rpc_id)) {
            /* permission denied */
            return {.result = -EACCES, .client_timestamp = remote_timestamp};
          } else {
            /* cannot find handler */
            return {.result = -ENOENT, .client_timestamp = remote_timestamp};
          }
        }

        /* safety check message size */
        if (len < record->size) {
          /* not enough data to read static payload */
          return {.result = -EAGAIN, .client_timestamp = remote_timestamp};
        }

        /* transform the message */
        u64 dst_buffer[(«max_message_size» + 7) / 8]; /* 64-bit aligned dst */
        uint16_t size = record->xform(msg, (char *)dst_buffer);

        /* if we didn't get all the dynamic sized part, request more bytes */
        if (size > len) {
          /* not enough data to read dynamic payload */
          return {.result = -EAGAIN, .client_timestamp = remote_timestamp};
        }

        /* call the handler function */
        (record->handler_fn)(record->context, remote_timestamp.count(), (char *)dst_buffer);

        return {.result = static_cast<int>(size + sizeof(u64)), .client_timestamp = remote_timestamp};
      «ENDIF»
    }

    /******************************************************************************
     * PROTOCOL CLASS: handle_multiple
     ******************************************************************************/
    Protocol::handle_result_t Protocol::handle_multiple(const char *msg, u64 len)
    {
      u64 processed = 0;
      u64 remaining = len;
      int ret = 0;
      u16 count = 0;
      auto client_timestamp = std::chrono::nanoseconds::zero();

      while (len > processed) {
        auto const handled = handle(msg + processed,
            (remaining > ((u32)-1) ? ((u32)-1) : remaining));
        ret = handled.result;
        client_timestamp = handled.client_timestamp;
        assert(ret != 0);
        if (ret < 0) {
          /* error while handling the message */
          break;
        }
        assert ((u32)ret <= remaining);

        /* sanity check, should not happen */
        if (((u64)ret + processed > len) || (((u64)ret + processed) < processed)) {
          throw std::runtime_error("«app.pkg.name»::«app.name»::Protocol::handle_multiple: possible overflow");
        }

        processed += ret;
        remaining -= ret;
        ++count;
      }

      if (processed > 0) {
        return {.result = static_cast<int>(processed), .client_timestamp = client_timestamp};
      }

      /* error, return code (or in edge case of len == 0, returns 0) */
      return {.result = ret, .client_timestamp = client_timestamp};
    }

    /******************************************************************************
     * PROTOCOL CLASS: add handler
     ******************************************************************************/
    void Protocol::add_handler(u16 rpc_id, void *context, handler_func_t handler_fn)
    {
      func_info *record = funcs_.insert(rpc_id, func_info{ context, handler_fn, });
      if (record == nullptr) {
        throw std::runtime_error("Protocol::add_handler: unable to insert handler_fn for rpc_id=" + std::to_string(rpc_id));
      }
    }

    «IF app.jit»
    /******************************************************************************
     * PROTOCOL CLASS: transform insert
     ******************************************************************************/
    void Protocol::insert_transform(u16 rpc_id, transform xform,
        u32 size, std::shared_ptr<jitbuf::TransformRecord> &transform_ptr)
    {
      /* find our handler function */
      auto func_info_p = funcs_.find(rpc_id);
      if (func_info_p == nullptr) {
        throw std::runtime_error("Protocol::insert_transform: handler not found for rpc_id=" + std::to_string(rpc_id));
      }

      handler_info *record = handlers_.insert(rpc_id, handler_info{
          .xform = xform,
          .context = func_info_p->context,
          .handler_fn = func_info_p->handler_fn,
          .size = size,
          .transform_ptr = transform_ptr });
      if (record == nullptr) {
        throw std::runtime_error("Protocol::insert_transform: unable to insert transform for rpc_id=" + std::to_string(rpc_id));
      }
    }
    «ENDIF»

    /******************************************************************************
     * PROTOCOL CLASS: insert_identity_transform with RPC ID
     ******************************************************************************/
    void Protocol::insert_identity_transform(u16 rpc_id)
    {
      /* find our handler function */
      auto func_info_p = funcs_.find(rpc_id);
      if (func_info_p == nullptr) {
        throw std::runtime_error("Protocol::insert_identity_transform: handler not found for rpc_id=" + std::to_string(rpc_id));
      }

      handler_info *record = handlers_.insert(rpc_id, handler_info{
          .xform = builder_.get_identity(rpc_id),
          .context = func_info_p->context,
          .handler_fn = func_info_p->handler_fn,
          .size = builder_.get_identity_size(rpc_id),
        «IF app.jit»
          .transform_ptr = nullptr
        «ENDIF»
      });
      if (record == nullptr) {
        throw std::runtime_error("Protocol::insert_identity_transform: unable to insert identity transform for rpc_id=" + std::to_string(rpc_id));
      }
    }

    /******************************************************************************
     * PROTOCOL CLASS: insert_no_auth_identity_transforms
     ******************************************************************************/
    void Protocol::insert_no_auth_identity_transforms()
    {
      «FOR msg : messages»
        «IF msg.noAuthorizationNeeded»
          /* «msg.span.name»: «app.name».«msg.name» */
          insert_identity_transform(«msg.wire_msg.rpc_id»);
        «ENDIF»
      «ENDFOR»
    }

    /******************************************************************************
     * PROTOCOL CLASS: insert_need_auth_identity_transforms
     ******************************************************************************/
    void Protocol::insert_need_auth_identity_transforms()
    {
      «FOR msg : messages»
        «IF !msg.noAuthorizationNeeded»
          /* «msg.span.name»: «app.name».«msg.name» */
          insert_identity_transform(«msg.wire_msg.rpc_id»);
        «ENDIF»
      «ENDFOR»
    }

    } // namespace «app.pkg.name»::«app.name»
    '''
  }
}
