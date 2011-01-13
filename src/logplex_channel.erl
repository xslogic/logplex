%% Copyright (c) 2010 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(logplex_channel).
-behaviour(gen_server).

%% gen_server callbacks
-export([start_link/0, init/1, handle_call/3, handle_cast/2, 
	     handle_info/2, terminate/2, code_change/3]).

-export([create/3, delete/1, update_addon/2, lookup/1, logs/2, tokens/1, drains/1, info/1, refresh_dns/0]).

-include_lib("logplex.hrl").

%% API functions
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create(ChannelName, AppId, Addon) when is_binary(ChannelName), is_integer(AppId), is_binary(Addon) ->
  Id = get_id(),
  Props = [{name, ChannelName}, {app_id, AppId}, {addon, Addon}],
  Json = mochijson2:encode({struct, Props}),
  {ok, _} = doozer:set("0", create_path(channels) ++ integer_to_list(Id), iolist_to_binary(Json)),
  Id.


delete(ChannelId) when is_integer(ChannelId) ->
    case lookup(ChannelId) of
        undefined ->
            {error, not_found};
        _ ->
            logplex_grid:publish(?MODULE, {delete_channel, ChannelId}),
            logplex_grid:publish(logplex_token, {delete_channel, ChannelId}),
            logplex_grid:publish(logplex_drain, {delete_channel, ChannelId}),
            redis_helper:delete_channel(ChannelId)
    end.

update_addon(ChannelId, Addon) when is_integer(ChannelId), is_binary(Addon) ->
    case lookup(ChannelId) of
        undefined ->
            {error, not_found};
        Channel ->
            logplex_grid:publish(?MODULE, {update_channel, Channel#channel{addon=Addon}}),
            logplex_grid:publish(logplex_token, {update_addon, ChannelId, Addon}),
            redis_helper:update_channel_addon(ChannelId, Addon)
    end.

lookup(ChannelId) when is_integer(ChannelId) ->
    case ets:lookup(?MODULE, ChannelId) of
        [Channel] -> Channel;
        _ -> undefined
    end.

logs(ChannelId, Num) when is_integer(ChannelId), is_integer(Num) ->
    [{logplex_read_queue_map, {Map, Interval}}] = ets:lookup(logplex_shard_info, logplex_read_queue_map),
    Index = redis_shard:key_to_index(integer_to_list(ChannelId)),
    {_RedisUrl, QueuePid} = redis_shard:get_matching_pool(Index, Map, Interval),
    Packet = redis:build_request([<<"LRANGE">>, iolist_to_binary(["ch:", integer_to_list(ChannelId), ":spool"]), <<"0">>, list_to_binary(integer_to_list(Num))]),
    logplex_queue:in(QueuePid, {self(), Packet}),
    receive
        {logs, Logs} -> Logs
    after 60 * 1000 ->
        {error, timeout}
    end.

tokens(ChannelId) when is_integer(ChannelId) ->
    ets:lookup(logplex_channel_tokens, ChannelId).

drains(ChannelId) when is_integer(ChannelId) ->
    ets:lookup(logplex_channel_drains, ChannelId).

info(ChannelId) when is_integer(ChannelId) ->
    case lookup(ChannelId) of
        #channel{name=ChannelName, app_id=AppId, addon=Addon} ->
            [{channel_id, ChannelId},
             {channel_name, ChannelName},
             {app_id, AppId},
             {addon, Addon},
             {tokens, lists:sort([{Name, Token} || #token{id=Token, name=Name} <- tokens(ChannelId)])},
             {drains, [iolist_to_binary([<<"syslog://">>, Host, ":", integer_to_list(Port)]) || #drain{host=Host, port=Port} <- drains(ChannelId)]}];
        _ ->
            []
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%% @hidden
%%--------------------------------------------------------------------
init([]) ->
    ets:new(?MODULE, [protected, named_table, set, {keypos, 2}]),
    ets:new(logplex_channel_tokens, [protected, named_table, bag, {keypos, 3}]),
    ets:new(logplex_channel_drains, [protected, named_table, bag, {keypos, 3}]),
    Env = binary_to_list(logplex_utils:heorku_domain()),
    ChannelPath = "/" ++ Env ++ "/channels/*",
    %% TokenPath = "/" ++ Env ++ "/channels/*/tokens/*",
    %% DrainPath = "/" ++ Env ++ "/channels/*/drains/*",
    lists:foreach(
      fun(Path) ->
          {sent, _} = doozer:walk(self(), Path),
          {sent, _} = doozer:watch(self(), Path)
      end, [ChannelPath]),
    %% populate_cache(),
    spawn_link(fun refresh_dns/0),
    {ok, []}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%% @hidden
%%--------------------------------------------------------------------
handle_call(_Msg, _From, State) ->
    {reply, {error, invalid_call}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_cast({resolve_host, Ip, Drain}, State) ->
    ets:delete_object(logplex_channel_drains, Drain),
    ets:insert(logplex_channel_drains, Drain#drain{resolved_host=Ip}),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_info({create, ChannelId, ChannelName, AppId, Addon}, State) ->
    ets:insert(?MODULE, #channel{id=ChannelId, name=ChannelName, app_id=AppId, addon=Addon}),
    {noreply, State};

handle_info({update_channel, #channel{id=ChannelId, addon=Addon}=Channel}, State) ->
    ets:insert(?MODULE, Channel),
    [begin
        ets:delete_object(logplex_channel_tokens, Token),
        ets:insert(logplex_channel_tokens, Token#token{addon=Addon})
    end || Token <- ets:lookup(logplex_channel_tokens, ChannelId)],
    {noreply, State};

handle_info({delete_channel, ChannelId}, State) ->
    ets:delete(?MODULE, ChannelId),
    ets:match_delete(logplex_channel_tokens, #token{id='_', channel_id=ChannelId, name='_', app_id='_', addon='_'}),
    ets:match_delete(logplex_channel_drains, #drain{id='_', channel_id=ChannelId, resolved_host='_', host='_', port='_'}),
    {noreply, State};

handle_info({create_token, ChannelId, TokenId, TokenName, AppId, Addon}, State) ->
    ets:insert(logplex_channel_tokens, #token{id=TokenId, channel_id=ChannelId, name=TokenName, app_id=AppId, addon=Addon}),
    {noreply, State};

handle_info({delete_token, ChannelId, TokenId}, State) ->
    ets:match_delete(logplex_channel_tokens, #token{id=TokenId, channel_id=ChannelId, name='_', app_id='_', addon='_'}),
    {noreply, State};

handle_info({create_drain, DrainId, ChannelId, ResolvedHost, Host, Port}, State) ->
    ets:insert(logplex_channel_drains, #drain{id=DrainId, channel_id=ChannelId, resolved_host=ResolvedHost, host=Host, port=Port}),
    {noreply, State};

handle_info({delete_drain, DrainId}, State) ->
    ets:match_delete(logplex_channel_drains, #drain{id=DrainId, channel_id='_', resolved_host='_', host='_', port='_'}),
    {noreply, State};

handle_info({Op, valid, _, PropList}, State) ->
  case lists:member(Op, [watch, walk, monitor]) of
    true ->
      {Path, Value} = {proplists:get_value(path, PropList), proplists:get_value(value, PropList)},
      [Id | _] = lists:reverse(string:tokens(Path, "/")),
      Cas = proplists:get_value(cas, PropList),
      case Cas of
        "0" -> delete_new("channels", Id);
        _ -> 
          {struct, Props} = mochijson2:decode(Value),
          create_new("channels", Id, Props)
      end;
    _ -> void
  end,    
  {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%% @hidden
%%--------------------------------------------------------------------
terminate(_Reason, _State) -> 
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%% @hidden
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
populate_cache() ->
    Channels = redis_helper:lookup_channels(),
    length(Channels) > 0 andalso ets:insert(?MODULE, Channels),

    Tokens = [begin
        case logplex_channel:lookup(Token#token.channel_id) of
            #channel{app_id=AppId, addon=Addon} -> Token#token{app_id=AppId, addon=Addon};
            _ -> Token
        end
    end || Token <- redis_helper:lookup_tokens()],
    length(Tokens) > 0 andalso ets:insert(logplex_channel_tokens, Tokens),

    Drains = lists:foldl(
        fun(#drain{host=Host}=Drain, Acc) ->
            case logplex_utils:resolve_host(Host) of
                undefined -> Acc;
                Ip -> [Drain#drain{resolved_host=Ip}|Acc]
            end
        end, [], redis_helper:lookup_drains()),
    length(Drains) > 0 andalso ets:insert(logplex_channel_drains, Drains),

    ok.

refresh_dns() ->
    timer:sleep(60 * 1000),
    [begin
        case logplex_utils:resolve_host(Host) of
            undefined -> ok;
            Ip -> gen_server:cast(?MODULE, {resolve_host, Ip, Drain})
        end
    end || #drain{host=Host}=Drain <- ets:tab2list(logplex_channel_drains)],
    ?MODULE:refresh_dns().

get_id() ->
  Path = "/" ++ binary_to_list(logplex_utils:heorku_domain()) ++ "/channelid",
  {ok, PList} = doozer:get(Path, 0),
  NextId = 
    case proplists:get_value(value, PList) of
      <<>> -> 1;
      X -> list_to_integer(binary_to_list(X)) + 1
    end,
  case doozer:set(proplists:get_value(cas, PList), Path, list_to_binary(integer_to_list(NextId))) of
    {ok, _} -> NextId;
    _ -> get_id()
  end.
      

create_path(Type) ->  
  "/" ++ binary_to_list(logplex_utils:heorku_domain()) ++ "/" ++ atom_to_list(Type) ++ "/".
      
create_new("channels", Id, Props) ->
  ets:insert(?MODULE, #channel{id = Id, 
                               name = proplists:get_value(<<"name">>, Props), 
                               app_id = proplists:get_value(<<"app_id">>, Props), 
                               addon = proplists:get_value(<<"addon">>, Props)});
create_new("tokens", Id, Props) ->
  ets:insert(logplex_channel_tokens, #token{id = Id, 
                                            name = proplists:get_value(name, Props), 
                                            channel_id = proplists:get_value(channel_id, Props), 
                                            app_id = proplists:get_value(app_id, Props), 
                                            addon = proplists:get_value(addon, Props)});

create_new("drains", Id, Props) ->
  ets:insert(logplex_channel_drains, #drain{id = Id, 
                                            channel_id = proplists:get_value(channel_id, Props), 
                                            resolved_host = proplists:get_value(resolved_host, Props), 
                                            host = proplists:get_value(host, Props), 
                                            port = proplists:get_value(port, Props)}).

delete_new("channels", ChannelId) ->
  ets:delete(?MODULE, ChannelId),
  ets:match_delete(logplex_channel_tokens, #token{id='_', channel_id=ChannelId, name='_', app_id='_', addon='_'}),
  ets:match_delete(logplex_channel_drains, #drain{id='_', channel_id=ChannelId, resolved_host='_', host='_', port='_'}).

  
