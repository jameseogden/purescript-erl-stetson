module Stetson.RestHandler where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Uncurried (EffectFn2, mkEffectFn2)
import Erl.Atom (atom)
import Erl.Cowboy.Handlers.Rest (AcceptCallback(..), AllowedMethodsHandler, ContentType(..), ContentTypesAcceptedHandler, ContentTypesProvidedHandler, DeleteResourceHandler, ForbiddenHandler, InitHandler, IsAuthorizedHandler, IsConflictHandler, MovedPermanentlyHandler, MovedTemporarilyHandler, PreviouslyExistedHandler, ProvideCallback(..), ResourceExistsHandler, ServiceAvailableHandler, MalformedRequestHandler, authorized, contentTypesAcceptedResult, contentTypesProvidedResult, initResult, unauthorized)
import Erl.Cowboy.Handlers.Rest (RestResult, restResult) as Cowboy
import Erl.Cowboy.Req (Req)
import Erl.Data.List (List, mapWithIndex, nil, (!!))
import Erl.Data.Tuple (tuple2, uncurry2)
import Stetson (InitResult(..), RestHandler, RestResult(..), Authorized(..))
import Unsafe.Coerce (unsafeCoerce)

type State state =
  { handler :: RestHandler state
  , innerState :: state
  , acceptHandlers :: List (Req -> state -> Effect (RestResult Boolean state))
  , provideHandlers :: List (Req -> state -> Effect (RestResult String state))
  }

init :: forall state. InitHandler (RestHandler state) (State state)
init = mkEffectFn2 \req handler -> do
  (InitOk req2 innerState) <- handler.init req
  pure $ initResult { handler, innerState, acceptHandlers : nil, provideHandlers : nil } req2

resource_exists :: forall state. ResourceExistsHandler (State state)
resource_exists = mkEffectFn2 \req state@{ handler } -> do
  call handler.resourceExists req state

allowed_methods :: forall state. AllowedMethodsHandler (State state)
allowed_methods = mkEffectFn2 \req state@{ handler, innerState } -> do
  callMap (map show) handler.allowedMethods req state

malformed_request :: forall state. MalformedRequestHandler (State state)
malformed_request = mkEffectFn2 \req state@{ handler, innerState } -> do
  call handler.malformedRequest req state

previously_existed :: forall state. PreviouslyExistedHandler (State state)
previously_existed = mkEffectFn2 \req state@{ handler, innerState } -> do
  call handler.previouslyExisted req state

allow_missing_post :: forall state. PreviouslyExistedHandler (State state)
allow_missing_post = mkEffectFn2 \req state@{ handler, innerState } -> do
  call handler.allowMissingPost req state

moved_permanently :: forall state. MovedPermanentlyHandler (State state)
moved_permanently = mkEffectFn2 \req state@{ handler, innerState } -> do
  call handler.movedPermanently req state

moved_temporarily :: forall state. MovedTemporarilyHandler (State state)
moved_temporarily = mkEffectFn2 \req state@{ handler, innerState } -> do
  call handler.movedTemporarily req state

service_available :: forall state. ServiceAvailableHandler (State state)
service_available = mkEffectFn2 \req state@{ handler, innerState } -> do
  call handler.serviceAvailable req state

is_authorized :: forall state. IsAuthorizedHandler (State state)
is_authorized = mkEffectFn2 \req state@{ handler } -> do
  callMap convertAuth handler.isAuthorized req state
  where
  convertAuth Authorized = authorized
  convertAuth (NotAuthorized s) = unauthorized s

is_conflict :: forall state. IsConflictHandler (State state)
is_conflict = mkEffectFn2 \req state@{ handler } ->
  call handler.isConflict req state

forbidden :: forall state. ForbiddenHandler (State state)
forbidden = mkEffectFn2 \req state@{ handler } ->
  call handler.forbidden req state

delete_resource :: forall state. DeleteResourceHandler (State state)
delete_resource = mkEffectFn2 \req state@{ handler } -> do
  call handler.deleteResource req state

-- { "application", "json", call_foo }
-- { "application/json", call_foo }
-- { '*', call_foo }

content_types_accepted :: forall state. ContentTypesAcceptedHandler (State state)
content_types_accepted = mkEffectFn2 \req state@{ handler, innerState } ->
  case handler.contentTypesAccepted of
       Nothing -> noCall
       Just factory -> do
          RestOk callbacks req2 innerState2 <- factory req innerState
          let fns = map (\tuple -> uncurry2 (\ct fn -> fn) tuple) callbacks
              atoms = mapWithIndex (\tuple i -> uncurry2 (\ct _ -> tuple2 (SimpleContentType ct) $ AcceptCallback $ atom $ "accept_" <> show i) tuple) callbacks
          pure $ Cowboy.restResult (contentTypesAcceptedResult atoms) (state { innerState = innerState2, acceptHandlers = fns }) req2

-- TODO: iodata/stream/etc
content_types_provided :: forall state. ContentTypesProvidedHandler (State state)
content_types_provided = mkEffectFn2 \req state@{ handler, innerState } ->
  case handler.contentTypesProvided of
       Nothing -> noCall
       Just factory -> do
          RestOk callbacks req2 innerState2 <- factory req innerState
          let fns = map (\tuple -> uncurry2 (\ct fn -> fn) tuple) callbacks
              atoms = mapWithIndex (\tuple i -> uncurry2 (\ct _ -> tuple2 (SimpleContentType ct) $ ProvideCallback $ atom $ "provide_" <> show i) tuple) callbacks
          pure $ Cowboy.restResult (contentTypesProvidedResult atoms) (state { innerState = innerState2, provideHandlers = fns }) req2

callMap :: forall state reply mappedReply. (reply -> mappedReply) -> Maybe (Req -> state -> Effect (RestResult reply state)) -> Req -> (State state) -> Effect (Cowboy.RestResult mappedReply (State state))
callMap mapFn fn req state = restResult state $ map (mapReply mapFn) $ fn <*> pure req <*> pure state.innerState

call :: forall state reply. Maybe (Req -> state -> Effect (RestResult reply state)) -> Req -> State state -> Effect (Cowboy.RestResult reply (State state))
call fn req state = restResult state $ fn <*> pure req <*> pure state.innerState

mapReply :: forall state reply mappedReply. (reply -> mappedReply) -> Effect (RestResult reply state) -> Effect (RestResult mappedReply state)
mapReply mapFn org = do
  (RestOk re rq st) <- org
  pure $ RestOk (mapFn re) rq st

restResult :: forall reply state. State state -> Maybe (Effect (RestResult reply state)) -> Effect (Cowboy.RestResult reply (State state))
restResult outerState (Just result) = do
  (RestOk re rq st) <- result
  pure $ Cowboy.restResult re (outerState { innerState = st }) rq

-- This is an internal Cowboy detail, and we *must not* use the value from this once we've returned it
-- Cowboy may not support this in the future, but hopefully it will - essentially it means that
-- The function is entirely ignored and is therefore treated as optional
restResult outerState Nothing = noCall

noCall :: forall t3 t4. Applicative t3 => t3 t4
noCall = pure $ unsafeCoerce (atom "no_call")

accept :: forall state. Int -> EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept i = mkEffectFn2 \req state@{ acceptHandlers } ->
  call (acceptHandlers !! i) req state

provide :: forall state. Int -> EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide i = mkEffectFn2 \req state@{ provideHandlers } ->
  call (provideHandlers !! i) req state


accept_0 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept_0 = accept 0

accept_1 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept_1 = accept 1

accept_2 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept_2 = accept 2

accept_3 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept_3 = accept 3

accept_4 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept_4 = accept 4

accept_5 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept_5 = accept 5

accept_6 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult Boolean (State state))
accept_6 = accept 6

provide_0 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide_0 = provide 0

provide_1 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide_1 = provide 1

provide_2 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide_2 = provide 2

provide_3 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide_3 = provide 3

provide_4 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide_4 = provide 4

provide_5 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide_5 = provide 5

provide_6 :: forall state. EffectFn2 Req (State state) (Cowboy.RestResult String (State state))
provide_6 = provide 6
