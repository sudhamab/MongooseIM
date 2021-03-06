-module(dynamic_modules).

-include_lib("common_test/include/ct.hrl").

-export([save_modules/2, ensure_modules/2, restore_modules/2]).
-export([stop/2, start/3, restart/3, stop_running/2, start_running/1]).

save_modules(Domain, Config) ->
    [{saved_modules, get_current_modules(Domain)} | Config].

ensure_modules(Domain, RequiredModules) ->
    CurrentModules = get_current_modules(Domain),
    {ToReplace, ReplaceWith} = to_replace(RequiredModules, CurrentModules, [], []),
    ok = escalus_ejabberd:rpc(gen_mod_deps, replace_modules,
                              [Domain, ToReplace, ReplaceWith]).

to_replace([], _CurrentModules, ReplaceAcc, ReplaceWithAcc) ->
    {lists:usort(ReplaceAcc), ReplaceWithAcc};
to_replace([RequiredModule | Rest], CurrentModules, ReplaceAcc, ReplaceWithAcc) ->
    {Mod, Opts} = RequiredModule,
    {NewReplaceAcc, NewReplaceWithAcc} =
        case lists:keyfind(Mod, 1, CurrentModules) of
            false when Opts =:= stopped -> {ReplaceAcc, ReplaceWithAcc};
            false -> {ReplaceAcc, [RequiredModule | ReplaceWithAcc]};
            {Mod, Opts} -> {ReplaceAcc, ReplaceWithAcc};
            ExistingMod when Opts =:= stopped -> {[ExistingMod | ReplaceAcc], ReplaceWithAcc};
            ExistingMod -> {[ExistingMod | ReplaceAcc], [RequiredModule | ReplaceWithAcc]}
        end,
    to_replace(Rest, CurrentModules, NewReplaceAcc, NewReplaceWithAcc).

restore_modules(Domain, Config) ->
    SavedModules = ?config(saved_modules, Config),
    CurrentModules = get_current_modules(Domain),
    escalus_ejabberd:rpc(gen_mod_deps, replace_modules,
                         [Domain, CurrentModules, SavedModules]).

get_current_modules(Domain) ->
    escalus_ejabberd:rpc(gen_mod, loaded_modules_with_opts, [Domain]).

stop(Domain, Mod) ->
    IsLoaded = escalus_ejabberd:rpc(gen_mod, is_loaded, [Domain, Mod]),
    case IsLoaded of
        true -> unsafe_stop(Domain, Mod);
        false -> {error, stopped}
    end.

unsafe_stop(Domain, Mod) ->
    case escalus_ejabberd:rpc(gen_mod, stop_module, [Domain, Mod]) of
        {badrpc, Reason} ->
            ct:fail("Cannot stop module ~p reason ~p", [Mod, Reason]);
        R -> R
    end.

start(Domain, Mod, Args) ->
    case escalus_ejabberd:rpc(gen_mod, start_module, [Domain, Mod, Args]) of
        {badrpc, Reason} ->
            ct:fail("Cannot start module ~p reason ~p", [Mod, Reason]);
        R -> R
    end.

restart(Domain, Mod, Args) ->
    stop(Domain, Mod),
    ModStr = atom_to_list(Mod),
    case lists:reverse(ModStr) of
        "cbdo_" ++ Str -> %%check if we need to start odbc module or regular
            stop(Domain, list_to_atom(lists:reverse(Str)));
        Str ->
            stop(Domain, list_to_atom(lists:reverse(Str)++"_odbc"))
    end,
    start(Domain, Mod, Args).

start_running(Config) ->
    Domain = ct:get_config({hosts, mim, domain}),
    case ?config(running, Config) of
        List when is_list(List) ->
            _ = [start(Domain, Mod, Args) || {Mod, Args} <- List];
        _ ->
            ok
    end.

stop_running(Mod, Config) ->
    ModL = atom_to_list(Mod),
    Domain = escalus_ejabberd:unify_str_arg(
               ct:get_config({hosts, mim, domain})),
    Modules = escalus_ejabberd:rpc(ejabberd_config,
                                   get_local_option,
                                   [{modules, Domain}]),
    Filtered = lists:filter(fun({Module, _}) ->
                    ModuleL = atom_to_list(Module),
                    case lists:sublist(ModuleL, 1, length(ModL)) of
                        ModL -> true;
                        _ -> false
                    end;
                (_) -> false
            end, Modules),
    case Filtered of
        [] ->
            Config;
        [{Module,_Args}=Head|_] ->
            stop(Domain, Module),
            [{running, [Head]} | Config]
    end.
