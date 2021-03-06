%%%===================================================================
%%% @copyright (C) 2015, Erlang Solutions Ltd.
%%% @doc Suite for testing pubsub features as described in XEP-0060
%%% @Tools module - pubsub specific tools and high level
%%% @               wrappers for the escalus tool.
%%% @end
%%%===================================================================

-module(pubsub_tools).

-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("exml/include/exml.hrl").
-include_lib("exml/include/exml_stream.hrl").

%% Send request, receive (optional) response
-export([
         discover_nodes/3,

         create_node/3,
         delete_node/3,

         get_configuration/3,
         set_configuration/4,

         get_affiliations/3,
         set_affiliations/4,

         publish/4,
         retract_item/4,
         get_all_items/3,
         purge_all_items/3,

         subscribe/3,
         unsubscribe/3,
         get_user_subscriptions/3,
         get_node_subscriptions/3,
         submit_subscription_response/5,
         get_pending_subscriptions/3,
         get_pending_subscriptions/4,
         modify_node_subscriptions/4
        ]).

%% Receive notification or response
-export([receive_item_notification/4,
         receive_subscription_notification/4,
         receive_subscription_request/4,
         receive_subscription_requests/4,
         receive_node_creation_notification/3,
         receive_subscribe_response/3,
         receive_unsubscribe_response/3]).

%%-----------------------------------------------------------------------------
%% Request functions with (optional) built-in response handlers
%%-----------------------------------------------------------------------------

%% ------------------------ disco --------------------------------

discover_nodes(User, {NodeAddr, NodeName}, Options) ->
    %% discover child nodes
    Id = id(User, {NodeAddr, NodeName}, <<"disco_children">>),
    Request = escalus_pubsub_stanza:discover_nodes(User, Id, {NodeAddr, NodeName}),
    send_request_and_receive_response(
      User, Request, Id, Options,
      fun(Response, ExpectedResult) ->
              check_node_discovery_response(Response, {NodeAddr, NodeName}, ExpectedResult)
      end);
discover_nodes(User, NodeAddr, Options) ->
    %% discover top-level nodes
    Id = id(User, {NodeAddr, <<>>}, <<"disco_nodes">>),
    Request = escalus_pubsub_stanza:discover_nodes(User, Id, NodeAddr),
    send_request_and_receive_response(
      User, Request, Id, Options,
      fun(Response, ExpectedResult) ->
              check_node_discovery_response(Response, {NodeAddr, undefined}, ExpectedResult)
      end).

%% ------------------------ create & delete --------------------------------

create_node(User, Node, Options) ->
    Id = id(User, Node, <<"create_node">>),
    Config = proplists:get_value(config, Options, []),
    Request0 = escalus_pubsub_stanza:create_node(User, Id, Node, Config),

    Request =
        case proplists:get_value(type, Options, undefined) of
            undefined ->
                Request0;
            Type ->
                #xmlel{children = [
                    #xmlel{children = [CreateEl | OtherEls]} = PubsubEl
                ]} = IQ = Request0,
                NewCreateEl = CreateEl#xmlel{attrs = [{<<"type">>, Type} | CreateEl#xmlel.attrs]},
                NewPubsubEl = PubsubEl#xmlel{children = [NewCreateEl | OtherEls]},
                IQ#xmlel{children = [NewPubsubEl]}
        end,

    send_request_and_receive_response(User, Request, Id, Options).

delete_node(User, Node, Options) ->
    Id = id(User, Node, <<"delete_node">>),
    Request = escalus_pubsub_stanza:delete_node(User, Id, Node),
    send_request_and_receive_response(User, Request, Id, Options).

%% ------------------------ config --------------------------------

get_configuration(User, Node, Options) ->
    Id = id(User, Node, <<"get_config">>),
    Request = escalus_pubsub_stanza:get_configuration(User, Id, Node),
    decode_config_form(send_request_and_receive_response(User, Request, Id, Options)).

set_configuration(User, Node, Config, Options) ->
    Id = id(User, Node, <<"set_config">>),
    Request = escalus_pubsub_stanza:set_configuration(User, Id, Node, Config),
    send_request_and_receive_response(User, Request, Id, Options).

%% ------------------------ affiliations --------------------------------

get_affiliations(User, Node, Options) ->
    Id = id(User, Node, <<"get_affs">>),
    Request = escalus_pubsub_stanza:get_affiliations(User, Id, Node),
    decode_affiliations(send_request_and_receive_response(User, Request, Id, Options)).

set_affiliations(User, Node, AffChange, Options) ->
    Id = id(User, Node, <<"set_affs">>),
    Request = escalus_pubsub_stanza:set_affiliations(User, Id, Node, AffChange),
    send_request_and_receive_response(User, Request, Id, Options).

%% ------------------------ publishing & items --------------------------------

publish(User, ItemId, Node, Options) ->
    Id = id(User, Node, <<"publish">>),
    Request = case proplists:get_value(with_payload, Options, true) of
                  true -> escalus_pubsub_stanza:publish(User, ItemId, item_content(), Id, Node);
                  false -> escalus_pubsub_stanza:publish(User, Id, Node)
              end,
    send_request_and_receive_response(User, Request, Id, Options).

retract_item(User, Node, ItemId, Options) ->
    Id = id(User, Node, <<"retract">>),
    Request = escalus_pubsub_stanza:retract(User, Id, Node, ItemId),
    send_request_and_receive_response(User, Request, Id, Options).

get_all_items(User, {_, NodeName} = Node, Options) ->
    Id = id(User, Node, <<"items">>),
    Request = escalus_pubsub_stanza:get_all_items(User, Id, Node),
    send_request_and_receive_response(
      User, Request, Id, Options,
      fun(Response, ExpectedResult) ->
              Items = exml_query:path(Response, [{element, <<"pubsub">>},
                                                 {element, <<"items">>}]),
              check_items(Items, ExpectedResult, NodeName, true)
      end).

purge_all_items(User, Node, Options) ->
    Id = id(User, Node, <<"purge">>),
    Request = escalus_pubsub_stanza:purge_all_items(User, Id, Node),
    send_request_and_receive_response(User, Request, Id, Options).

%% ------------------------ subscriptions --------------------------------

subscribe(User, Node, Options) ->
    Jid = jid(User, proplists:get_value(jid_type, Options, full)),
    Id = id(User, Node, <<"subscribe">>),
    Config = proplists:get_value(config, Options, []),
    Request = escalus_pubsub_stanza:subscribe(Jid, Id, Node, Config),
    send_request_and_receive_response(
      User, Request, Id, [{expected_result, true} | Options],
      fun(Response) ->
              check_subscription_response(Response, User, Node, Options)
      end).

unsubscribe(User, Node, Options) ->
    Jid = jid(User, proplists:get_value(jid_type, Options, full)),
    Id = id(User, Node, <<"unsubscribe">>),
    Request = escalus_pubsub_stanza:unsubscribe(Jid, Id, Node),
    send_request_and_receive_response(User, Request, Id, Options).

get_user_subscriptions(User, NodeAddr, Options) ->
    Id = id(User, {NodeAddr, <<>>}, <<"user_subscriptions">>),
    Request = escalus_pubsub_stanza:get_user_subscriptions(User, Id, NodeAddr),
    send_request_and_receive_response(
      User, Request, Id, Options,
      fun(Response, ExpectedResult) ->
              check_user_subscriptions_response(User, Response, ExpectedResult)
      end).

get_node_subscriptions(User, Node, Options) ->
    Id = id(User, Node, <<"node_subscriptions">>),
    Request = escalus_pubsub_stanza:get_node_subscriptions(User, Id, Node),
    send_request_and_receive_response(
      User, Request, Id, Options,
      fun(Response, ExpectedResult) ->
              check_node_subscriptions_response(Response, ExpectedResult, Node)
      end).

submit_subscription_response(User, {MsgId, SubForm}, Node, Allow, Options) ->
    Key = <<"pubsub#allow">>,
    NewSubForm = lists:keyreplace(Key, 1, SubForm, {Key, <<"boolean">>, bool2bin(Allow)}),
    Request = escalus_pubsub_stanza:submit_subscription_response(User, MsgId, Node, NewSubForm),
    send_request_and_receive_response(User, Request, MsgId, Options ++ [{receive_response, false}]).

get_pending_subscriptions(User, Node, Options) ->
    Id = id(User, Node, <<"request_pending_subscriptions">>),
    Request = escalus_pubsub_stanza:get_pending_subscriptions(User, Id, Node),
    send_request_and_receive_response(User, Request, Id, Options),
    Request.

get_pending_subscriptions(User, NodesAddr, NodeNames, Options) ->
    Id = id(User, {<<>>, <<>>}, <<"get_pending_subscriptions">>),
    Request = escalus_pubsub_stanza:get_pending_subscriptions(User, Id, NodesAddr),
    Response = send_request_and_receive_response(User, Request, Id, Options),
    check_pending_subscriptions(Response, NodeNames).

modify_node_subscriptions(User, ModifiedSubscriptions, Node, Options) ->
    Id = id(User, Node, <<"modify_node_subs">>),
    Subs = fill_subscriptions_jids(ModifiedSubscriptions),
    Request = escalus_pubsub_stanza:set_subscriptions(User, Id, Subs, Node),
    send_request_and_receive_response(User, Request, Id, Options).

%%-----------------------------------------------------------------------------
%% Receive functions for notifications and responses
%%-----------------------------------------------------------------------------

receive_item_notification(User, ItemId, {NodeAddr, NodeName}, Options) ->
    Stanza = receive_notification(User, NodeAddr, Options),
    check_item_notification(Stanza, ItemId, {NodeAddr, NodeName}, Options).

receive_subscription_notification(User, Subscription, {NodeAddr, NodeName}, Options) ->
    Stanza = receive_notification(User, NodeAddr, Options),
    check_subscription_notification(User, Stanza, Subscription, NodeName, Options).

receive_subscription_request(User, Requester, {NodeAddr, NodeName}, Options) ->
    Stanza = receive_notification(User, NodeAddr, Options),
    check_subscription_request(Stanza, Requester, NodeName, Options).

receive_subscription_requests(User, Requesters, {NodeAddr, NodeName}, Options) ->
    Stanzas = [ receive_notification(User, NodeAddr, Options) || _ <- Requesters ],

    true =
    lists:all(
      fun(Requester) ->
              lists:any(
                fun(Stanza) ->
                        element(1, catch check_subscription_request(
                                           Stanza, Requester, NodeName, Options))
                        =/= 'EXIT'
                end, Stanzas)
      end, Requesters).

receive_node_creation_notification(User, {NodeAddr, NodeName}, Options) ->
    Stanza = receive_notification(User, NodeAddr, Options),
    check_node_creation_notification(Stanza, NodeName).

receive_subscribe_response(User, Node, Options) ->
    Id = id(User, Node, <<"subscribe">>),
    Stanza = receive_response(User, Id, Options),
    check_subscription_response(Stanza, User, Node, Options).

receive_unsubscribe_response(User, Node, Options) ->
    Id = id(User, Node, <<"unsubscribe">>),
    Stanza = receive_response(User, Id, Options),
    check_response(Stanza, Id),
    Stanza.

%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------

check_subscription_response(Response, User, {_, NodeName}, Options) ->
    Jid = jid(User, proplists:get_value(jid_type, Options, full)),
    Subscription = exml_query:path(Response, [{element, <<"pubsub">>},
                                              {element, <<"subscription">>}]),
    check_subscription(Subscription, Jid, NodeName, Options),
    Response.

check_user_subscriptions_response(User, Response, ExpectedSubscriptions) ->
    SubscriptionElems = exml_query:paths(Response, [{element, <<"pubsub">>},
                                                    {element, <<"subscriptions">>},
                                                    {element, <<"subscription">>}]),
    Jid = escalus_utils:get_jid(User),
    [assert_ljid_equal(Jid, exml_query:attr(Subscr, <<"jid">>)) || Subscr <- SubscriptionElems],
    Subscriptions = [{exml_query:attr(Subscr, <<"node">>),
                      exml_query:attr(Subscr, <<"subscription">>)} || Subscr <- SubscriptionElems],
    ExpectedSorted = lists:sort(ExpectedSubscriptions),
    ExpectedSorted = lists:sort(Subscriptions),
    Response.

check_node_subscriptions_response(Response, ExpectedSubscriptions, {_, NodeName}) ->
    SubscriptionsElem = exml_query:path(Response, [{element, <<"pubsub">>},
                                                   {element, <<"subscriptions">>}]),
    NodeName = exml_query:attr(SubscriptionsElem, <<"node">>),
    SubscriptionElems = exml_query:subelements(SubscriptionsElem, <<"subscription">>),
    Subscriptions = [{exml_query:attr(Subscr, <<"jid">>),
                      exml_query:attr(Subscr, <<"subscription">>)} || Subscr <- SubscriptionElems],
    SubsWithLJids = convert_subscriptions_to_ljids(fill_subscriptions_jids(ExpectedSubscriptions)),
    SubsWithLJids = convert_subscriptions_to_ljids(lists:sort(Subscriptions)).

check_node_discovery_response(Response, {NodeAddr, NodeName}, ExpectedNodes) ->
    Query = exml_query:subelement(Response, <<"query">>),
    NodeName = exml_query:attr(Query, <<"node">>),
    Items = exml_query:subelements(Query, <<"item">>),
    [NodeAddr = exml_query:attr(Item, <<"jid">>) || Item <- Items],
    ReceivedNodes = [exml_query:attr(Item, <<"node">>) || Item <- Items],
    ReceivedSet = ordsets:from_list(ReceivedNodes),
    case ExpectedNodes of
        {no, NoNodeName} ->
            false = ordsets:is_element(NoNodeName, ReceivedSet);
        _ ->
            ExpectedSet = ordsets:from_list(ExpectedNodes),
            true = ordsets:is_subset(ExpectedSet, ReceivedSet)
    end,

    Response.

check_subscription_notification(User, Response, Subscription, NodeName, Options) ->
    SubEl =
    case exml_query:subelement(Response, <<"pubsub">>) of
        undefined -> exml_query:subelement(Response, <<"event">>);
        PubSubElem -> PubSubElem
    end,
    SubscriptionElem = exml_query:subelement(SubEl, <<"subscription">>),
    Jid = jid(User, proplists:get_value(jid_type, Options, full)),
    assert_ljid_equal(Jid, exml_query:attr(SubscriptionElem, <<"jid">>)),
    Subscription = exml_query:attr(SubscriptionElem, <<"subscription">>),
    NodeName = exml_query:attr(SubscriptionElem, <<"node">>),
    Response.

check_subscription_request(Stanza, Requester, NodeName, Options) ->
    DecodedForm =
    [ decode_form_field(F)
      || F <- exml_query:paths(Stanza, [{element, <<"x">>}, {element, <<"field">>}]) ],
    
    RequesterJid = escalus_utils:jid_to_lower(
                     jid(Requester, proplists:get_value(jid_type, Options, full))),
    {_, _, RequesterJid} = lists:keyfind(<<"pubsub#subscriber_jid">>, 1, DecodedForm),

    {_, _, NodeName} = lists:keyfind(<<"pubsub#node">>, 1, DecodedForm),

    {exml_query:attr(Stanza, <<"id">>), DecodedForm}.

check_pending_subscriptions(Stanza, Nodes) ->
    RetrievedNodes =
    exml_query:paths(Stanza, [{element, <<"command">>}, {element, <<"x">>}, {element, <<"field">>},
                              {element, <<"option">>}, {element, <<"value">>}, cdata]),

    SortedNodes = lists:sort(Nodes),
    SortedNodes = lists:sort(RetrievedNodes).

check_node_creation_notification(Response, NodeName) ->
    NodeName = exml_query:path(Response, [{element, <<"event">>},
                                          {element, <<"create">>},
                                          {attr, <<"node">>}]),
    Response.

check_item_notification(Response, ItemId, {NodeAddr, NodeName}, Options) ->
    check_notification(Response, NodeAddr),
    true = escalus_pred:has_type(<<"headline">>, Response),
    Items = exml_query:path(Response, [{element, <<"event">>},
                                       {element, <<"items">>}]),
    check_items(Items, [ItemId], NodeName, proplists:get_value(with_payload, Options, true)),
    Response.

send_request_and_receive_response(User, Request, Id, Options) ->
    send_request_and_receive_response(User, Request, Id, Options, fun(R) -> R end).

send_request_and_receive_response(User, Request, Id, Options, CheckResponseF) ->
    escalus:send(User, Request),
    case {proplists:get_value(receive_response, Options, true),
          proplists:get_value(expected_error_type, Options, none)} of
        {false, _} ->
            ok;
        {true, none} ->
            receive_and_check_response(User, Id, Options, CheckResponseF);
        {true, ExpectedErrorType} ->
            receive_error_response(User, Id, ExpectedErrorType, Options)
    end.

receive_and_check_response(User, Id, Options, CheckF) ->
    Response = receive_response(User, Id, Options),
    case proplists:get_value(expected_result, Options) of
        undefined -> Response;
        true -> CheckF(Response);
        ExpectedResult -> CheckF(Response, ExpectedResult)
    end.

receive_response(User, Id, Options) ->
    Stanza = receive_stanza(User, Options),
    check_response(Stanza, Id),
    Stanza.

check_response(Stanza, Id) ->
    true = escalus_pred:is_iq_result(Stanza),
    Id = exml_query:attr(Stanza, <<"id">>),
    Stanza.

receive_error_response(User, Id, Type, Options) ->
    ErrorStanza = receive_stanza(User, Options),
    true = escalus_pred:is_iq_error(ErrorStanza),
    Id = exml_query:attr(ErrorStanza, <<"id">>),
    ErrorElem = exml_query:subelement(ErrorStanza, <<"error">>),
    Type = exml_query:attr(ErrorElem, <<"type">>),
    ErrorStanza.

receive_notification(User, NodeAddr, Options) ->
    Stanza = receive_stanza(User, Options),
    check_notification(Stanza, NodeAddr),
    Stanza.

check_notification(Stanza, NodeAddr) ->
    true = escalus_pred:is_stanza_from(NodeAddr, Stanza),
    true = escalus_pred:is_message(Stanza),
    Stanza.

receive_stanza(User, Options) ->
    case proplists:get_value(stanza, Options) of
        undefined ->
            case proplists:get_value(response_timeout, Options) of
                undefined -> escalus:wait_for_stanza(User);
                Timeout -> escalus:wait_for_stanza(User, Timeout)
            end;
        Stanza ->
            Stanza
    end.

check_subscription(Subscr, Jid, NodeName, Options) ->
    assert_ljid_equal(Jid, exml_query:attr(Subscr, <<"jid">>)),
    NodeName = exml_query:attr(Subscr, <<"node">>),
    case proplists:get_value(subscription, Options) of
        undefined ->
            true = exml_query:attr(Subscr, <<"subid">>) =/= undefined,
            <<"subscribed">> = exml_query:attr(Subscr, <<"subscription">>);
        <<"pending">> ->
            <<"pending">> = exml_query:attr(Subscr, <<"subscription">>)
    end.

check_items(ReceivedItemsElem, ExpectedItemIds, NodeName, WithPayload) ->
    NodeName = exml_query:attr(ReceivedItemsElem, <<"node">>),
    ReceivedItems = exml_query:subelements(ReceivedItemsElem, <<"item">>),
    [check_item(ExpectedItemId, WithPayload, ReceivedItem) ||
        {ReceivedItem, ExpectedItemId} <- lists:zip(ReceivedItems, ExpectedItemIds)].

check_item(ExpectedItemId, WithPayload, ReceivedItem) ->
    ExpectedItemId = exml_query:attr(ReceivedItem, <<"id">>),
    Content = item_content(WithPayload),
    Content = exml_query:subelement(ReceivedItem, <<"entry">>).

item_content(false) -> undefined;
item_content(true) -> item_content().

bool2bin(true) -> <<"true">>;
bool2bin(false) -> <<"false">>.

convert_subscriptions_to_ljids(Subscriptions) ->
    [{escalus_utils:jid_to_lower(Jid), Sub} || {Jid, Sub} <- Subscriptions].

fill_subscriptions_jids(Subscriptions) ->
    [{jid(User, JidType), Subscr} || {User, JidType, Subscr} <- Subscriptions].

jid(User, full) -> escalus_utils:get_jid(User);
jid(User, bare) -> escalus_utils:get_short_jid(User).

assert_ljid_equal(ActualJid, ExpectedJid) ->
    LJid = escalus_utils:jid_to_lower(ExpectedJid),
    LJid = escalus_utils:jid_to_lower(ActualJid).

id(User, {NodeAddr, NodeName}, Suffix) ->
    UserName = escalus_utils:get_username(User),
    list_to_binary(io_lib:format("~s-~s-~s-~s", [UserName, NodeAddr, NodeName, Suffix])).

item_content() ->
    #xmlel{name = <<"entry">>,
           attrs = [{<<"xmlns">>, <<"http://www.w3.org/2005/Atom">>}]}.

decode_config_form(IQResult) ->
    PubSubNode = exml_query:subelement(IQResult, <<"pubsub">>),
    ?NS_PUBSUB_OWNER = exml_query:attr(PubSubNode, <<"xmlns">>),

    QPath = [{element, <<"configure">>}, {element, <<"x">>}, {element, <<"field">>}],
    Fields = exml_query:paths(PubSubNode, QPath),
    lists:map(fun decode_form_field/1, Fields).

decode_form_field(F) ->
    Var = exml_query:attr(F, <<"var">>),
    Type = exml_query:attr(F, <<"type">>),
    case exml_query:paths(F, [{element, <<"value">>}, cdata]) of
        [Value] -> {Var, Type, Value};
        Values -> {Var, Type, Values}
    end.

decode_affiliations(IQResult) ->
    PubSubNode = exml_query:subelement(IQResult, <<"pubsub">>),
    ?NS_PUBSUB_OWNER = exml_query:attr(PubSubNode, <<"xmlns">>),

    QPath = [{element, <<"affiliations">>}, {element, <<"affiliation">>}],
    Fields = exml_query:paths(PubSubNode, QPath),

    [ {exml_query:attr(F, <<"jid">>), exml_query:attr(F, <<"affiliation">>)} || F <- Fields ].

