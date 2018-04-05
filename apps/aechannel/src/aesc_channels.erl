%%%=============================================================================
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%%    ADT for channel objects
%%% @end
%%%=============================================================================
-module(aesc_channels).

-include_lib("apps/aecore/include/common.hrl").

%% API
-export([add_funds/3,
         deserialize/1,
         is_active/1,
         is_solo_closed/2,
         is_solo_closing/2,
         new/1,
         peers/1,
         serialize/1,
         slash/3,
         close_solo/3,
         subtract_funds/3]).

%% Getters
-export([id/1,
         id/3,
         initiator/1,
         initiator_amount/1,
         participant/1,
         participant_amount/1,
         channel_reserve/1,
         sequence_number/1]).

%%%===================================================================
%%% Types
%%%===================================================================

-type id()     :: binary().
-type amount() :: integer().
-type status()     :: 'active' | 'solo_closing'.
-type seq_number() :: non_neg_integer().

-record(channel, {id                 :: id(),
                  initiator          :: pubkey(),
                  participant        :: pubkey(),
                  initiator_amount   :: amount(),
                  participant_amount :: amount(),
                  channel_reserve    :: amount(),
                  sequence_number    :: seq_number(),
                  status             :: status(),
                  lock_period        :: non_neg_integer(),
                  closes_at          :: 'undefined' | height()}).

-opaque channel() :: #channel{}.

-type serialized() :: binary().

-export_type([id/0,
              amount/0,
              seq_number/0,
              channel/0,
              serialized/0]).

-define(CHANNEL_TYPE, <<"channel">>).
-define(CHANNEL_VSN, 1).

-define(PUB_SIZE, 65).
-define(NONCE_SIZE, 256).

%%%===================================================================
%%% API
%%%===================================================================

-spec add_funds(channel(), amount(), pubkey()) -> channel().
add_funds(#channel{} = Channel, Amount, PubKey) ->
    case initiator(Channel) =:= PubKey of
        true ->
            update_initiator_amount(Channel, Amount);
        false ->
            PubKey = participant(Channel),
            update_participant_amount(Channel, Amount)
    end.

-spec close_solo(channel(), aesc_offchain_tx:tx(), height()) -> channel().
close_solo(#channel{lock_period = LockPeriod} = Ch, State, Height) ->
    ClosesAt = Height + LockPeriod,
    Ch#channel{initiator_amount   = aesc_offchain_tx:initiator_amount(State),
               participant_amount = aesc_offchain_tx:participant_amount(State),
               sequence_number    = aesc_offchain_tx:sequence_number(State),
               closes_at          = ClosesAt}.

-spec deserialize(binary()) -> channel().
deserialize(Bin) ->
    {ok, List} = msgpack:unpack(Bin),
    [#{<<"type">>               := ?CHANNEL_TYPE},
     #{<<"vsn">>                := ?CHANNEL_VSN},
     #{<<"id">>                 := Id},
     #{<<"initiator">>          := InitiatorPubKey},
     #{<<"initiator_amount">>   := InitiatorAmount},
     #{<<"participant">>        := ParticipantPubKey},
     #{<<"participant_amount">> := ParticipantAmount},
     #{<<"channel_reserve">>    := ChannelReserve},
     #{<<"sequence_number">>    := SequenceNumber},
     #{<<"status">>             := Status},
     #{<<"lock_period">>        := LockPeriod},
     #{<<"closes_at">>          := ClosesAt0}] = List,
    ClosesAt = case ClosesAt0 of
                   0                    -> undefined;
                   H when is_integer(H) -> H
               end,
    #channel{id                 = Id,
             initiator          = InitiatorPubKey,
             initiator_amount   = InitiatorAmount,
             participant        = ParticipantPubKey,
             participant_amount = ParticipantAmount,
             channel_reserve    = ChannelReserve,
             sequence_number    = SequenceNumber,
             status             = binary_to_atom(Status, utf8),
             lock_period        = LockPeriod,
             closes_at          = ClosesAt}.

-spec is_active(channel()) -> boolean().
is_active(#channel{status = Status}) ->
    Status =:= active.

-spec is_solo_closed(channel(), height()) -> boolean().
is_solo_closed(#channel{status = Status, closes_at = ClosesAt}, Height) ->
    Status =:= solo_closing andalso ClosesAt =< Height.

-spec is_solo_closing(channel(), height()) -> boolean().
is_solo_closing(#channel{status = Status, closes_at = ClosesAt}, Height) ->
    Status =:= solo_closing andalso ClosesAt > Height.

-spec id(pubkey(), non_neg_integer(), pubkey()) -> pubkey().
id(InitiatorPubKey, Nonce, ParticipantPubKey) ->
    Bin = <<InitiatorPubKey:?PUB_SIZE/binary,
            Nonce:?NONCE_SIZE,
            ParticipantPubKey:?PUB_SIZE/binary>>,
    aec_hash:hash(pubkey, Bin).

-spec new(aesc_create_tx:tx()) -> channel().
new(ChCTx) ->
    Id = id(aesc_create_tx:initiator(ChCTx),
            aesc_create_tx:nonce(ChCTx),
            aesc_create_tx:participant(ChCTx)),
    #channel{id                 = Id,
             initiator          = aesc_create_tx:initiator(ChCTx),
             initiator_amount   = aesc_create_tx:initiator_amount(ChCTx),
             participant        = aesc_create_tx:participant(ChCTx),
             participant_amount = aesc_create_tx:participant_amount(ChCTx),
             channel_reserve    = aesc_create_tx:channel_reserve(ChCTx),
             sequence_number    = 0,
             status             = active,
             lock_period        = aesc_create_tx:lock_period(ChCTx)}.

-spec peers(channel()) -> list(pubkey()).
peers(#channel{} = Ch) ->
    [initiator(Ch), participant(Ch)].

-spec serialize(channel()) -> binary().
serialize(#channel{} = Ch) ->
    ClosesAt = case closes_at(Ch) of
                   undefined            -> 0;
                   H when is_integer(H) -> H
               end,
    msgpack:pack([#{<<"type">>               => ?CHANNEL_TYPE},
                  #{<<"vsn">>                => ?CHANNEL_VSN},
                  #{<<"id">>                 => id(Ch)},
                  #{<<"initiator">>          => initiator(Ch)},
                  #{<<"initiator_amount">>   => initiator_amount(Ch)},
                  #{<<"participant">>        => participant(Ch)},
                  #{<<"participant_amount">> => participant_amount(Ch)},
                  #{<<"channel_reserve">>    => channel_reserve(Ch)},
                  #{<<"sequence_number">>    => sequence_number(Ch)},
                  #{<<"status">>             => status(Ch)},
                  #{<<"lock_period">>        => lock_period(Ch)},
                  #{<<"closes_at">>          => ClosesAt}
                 ]).

-spec slash(channel(), aesc_offchain_tx:tx(), height()) -> channel().
slash(#channel{lock_period = LockPeriod} = Ch, State, Height) ->
    ClosesAt = Height + LockPeriod,
    Ch#channel{initiator_amount   = aesc_offchain_tx:initiator_amount(State),
               participant_amount = aesc_offchain_tx:participant_amount(State),
               sequence_number    = aesc_offchain_tx:sequence_number(State),
               closes_at          = ClosesAt}.

-spec subtract_funds(channel(), amount(), pubkey()) -> channel().
subtract_funds(#channel{} = Channel, Amount, PubKey) ->
    case initiator(Channel) =:= PubKey of
        true ->
            update_initiator_amount(Channel, -Amount);
        false ->
            PubKey = participant(Channel),
            update_participant_amount(Channel, -Amount)
    end.

%%%===================================================================
%%% Getters
%%%===================================================================

-spec closes_at(channel()) -> undefined | height().
closes_at(#channel{closes_at = ClosesAt}) ->
    ClosesAt.

-spec id(channel()) -> pubkey().
id(#channel{id = Id}) ->
    Id.

-spec initiator(channel()) -> pubkey().
initiator(#channel{initiator = InitiatorPubKey}) ->
    InitiatorPubKey.

-spec initiator_amount(channel()) -> amount().
initiator_amount(#channel{initiator_amount = InitiatorAmount}) ->
    InitiatorAmount.

-spec channel_reserve(channel()) -> amount().
channel_reserve(#channel{channel_reserve = ChannelReserve}) ->
    ChannelReserve.

-spec lock_period(channel()) -> non_neg_integer().
lock_period(#channel{lock_period = LockPeriod}) ->
    LockPeriod.

-spec participant(channel()) -> pubkey().
participant(#channel{participant = ParticipantPubKey}) ->
    ParticipantPubKey.

-spec participant_amount(channel()) -> amount().
participant_amount(#channel{participant_amount = ParticipantAmount}) ->
    ParticipantAmount.

-spec sequence_number(channel()) -> non_neg_integer().
sequence_number(#channel{sequence_number = SeqNumber}) ->
    SeqNumber.

-spec status(channel()) -> atom().
status(#channel{status = Status}) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec update_initiator_amount(channel(), amount()) -> channel().
update_initiator_amount(Channel, Amount) ->
    InitiatorAmount = initiator_amount(Channel),
    Channel#channel{initiator_amount = InitiatorAmount + Amount}.

-spec update_participant_amount(channel(), amount()) -> channel().
update_participant_amount(Channel, Amount) ->
    ParticipantAmount = participant_amount(Channel),
    Channel#channel{participant_amount = ParticipantAmount + Amount}.
