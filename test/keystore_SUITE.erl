-module(keystore_SUITE).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).
-import(config_parser_helper, [default_mod_config/1, mod_config/2]).

-define(ae(Expected, Actual), ?assertEqual(Expected, Actual)).

all() ->
    [
     module_startup_no_opts,
     module_startup_read_key_from_file,
     module_startup_create_ram_key,
     module_startup_create_ram_key_of_given_size,
     module_startup_for_multiple_domains,
     multiple_domains_one_stopped
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(jid),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    mongoose_config:set_opts(opts()),
    async_helper:start(Config, [{mongoose_instrument, start_link, []},
                                {mongooseim_helper, start_link_loaded_hooks, []}]).

end_per_suite(Config) ->
    async_helper:stop_all(Config),
    mongoose_config:erase_opts(),
    mnesia:stop(),
    mnesia:delete_schema([node()]).

init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, _Config) ->
    [mongoose_modules:ensure_stopped(Host, mod_keystore) || Host <- hosts()],
    mnesia:delete_table(key).

opts() ->
    maps:from_list([{hosts, hosts()},
                    {host_types, []},
                    {instrumentation, config_parser_helper:default_config([instrumentation])} |
                    [{{modules, Host}, #{}} || Host <- hosts()]]).

hosts() ->
    [<<"localhost">>, <<"first.com">>, <<"second.com">>].

%%
%% Tests
%%

module_startup_no_opts(_) ->
    {started, ok} = start(<<"localhost">>, default_mod_config(mod_keystore)).

module_startup_read_key_from_file(_) ->
    %% given
    RawKey = <<"qwe123">>,
    {ok, KeyFile} = key_at("/tmp/key-from-file", RawKey),
    %% when
    {started, ok} = start(<<"localhost">>, key_from_file(KeyFile)),
    %% then
    ?ae([{{key_from_file, <<"localhost">>}, RawKey}],
        get_key(<<"localhost">>, key_from_file)).

module_startup_create_ram_key(Config) ->
    module_startup_create_ram_key(Config, ram_key()),
    %% then we can access the key
    [{{ram_key, <<"localhost">>}, Key}] = get_key(<<"localhost">>, ram_key),
    true = is_binary(Key).

module_startup_create_ram_key_of_given_size(Config) ->
    KeySize = 4,
    module_startup_create_ram_key(Config, sized_ram_key(KeySize)),
    %% then
    [{{ram_key, <<"localhost">>}, Key}] = get_key(<<"localhost">>, ram_key),
    true = is_binary(Key),
    KeySize = byte_size(Key).

module_startup_create_ram_key(_, ModKeystoreOpts) ->
    %% given no key
    [] = get_key(<<"localhost">>, ram_key),
    %% when keystore starts with config to generate a memory-only key
    {started, ok} = start(<<"localhost">>, ModKeystoreOpts).

module_startup_for_multiple_domains(_Config) ->
    %% given
    [] = get_key(<<"first.com">>, key_from_file),
    [] = get_key(<<"second.com">>, key_from_file),
    FirstKey = <<"random-first.com-key-content">>,
    SecondKey = <<"random-second.com-key-content">>,
    {ok, FirstKeyFile} = key_at("/tmp/first.com", FirstKey),
    {ok, SecondKeyFile} = key_at("/tmp/second.com", SecondKey),
    %% when
    {started, ok} = start(<<"first.com">>, key_from_file(FirstKeyFile)),
    {started, ok} = start(<<"second.com">>, key_from_file(SecondKeyFile)),
    %% then
    ?ae([{{key_from_file, <<"first.com">>}, FirstKey}],
        get_key(<<"first.com">>, key_from_file)),
    ?ae([{{key_from_file, <<"second.com">>}, SecondKey}],
        get_key(<<"second.com">>, key_from_file)).

multiple_domains_one_stopped(_Config) ->
    % given
    [] = get_key(<<"first.com">>, key_from_file),
    [] = get_key(<<"second.com">>, key_from_file),
    FirstKey = <<"random-first.com-key-content">>,
    SecondKey = <<"random-second.com-key-content">>,
    {ok, FirstKeyFile} = key_at("/tmp/first.com", FirstKey),
    {ok, SecondKeyFile} = key_at("/tmp/second.com", SecondKey),
    % when
    {started, ok} = start(<<"first.com">>, key_from_file(FirstKeyFile)),
    {started, ok} = start(<<"second.com">>, key_from_file(SecondKeyFile)),
    ok = mod_keystore:stop(<<"first.com">>),
    % then
    ?ae([{{key_from_file, <<"second.com">>}, SecondKey}],
        get_key(<<"second.com">>, key_from_file)).

%%
%% Helpers
%%

key_at(Path, Data) ->
    ok = file:write_file(Path, Data),
    {ok, Path}.

key_from_file(KeyFile) ->
    mod_config(mod_keystore, #{keys => #{key_from_file => {file, KeyFile}}}).

ram_key() ->
    mod_config(mod_keystore, #{keys => #{ram_key => ram}}).

sized_ram_key(Size) ->
    mod_config(mod_keystore, #{keys => #{ram_key => ram},
                               ram_key_size => Size}).

%% Use a function like this in your module which is a client of mod_keystore.
-spec get_key(HostType, KeyName) -> Result when
      HostType :: mongooseim:host_type(),
      KeyName :: mod_keystore:key_name(),
      Result :: mod_keystore:key_list().
get_key(HostType, KeyName) ->
    mongoose_hooks:get_key(HostType, KeyName).

start(HostType, Opts) ->
    mongoose_modules:ensure_started(HostType, mod_keystore, Opts).
