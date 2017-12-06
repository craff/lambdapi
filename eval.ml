(** Evaluation and conversion. *)

open Extra
open Console
open Terms
open Print

(** [set_unif u v] sets the value of the unification variable [u] to [v]. Note
    that [u] should not have already been instanciated. *)
let set_unif : unif -> (term, term) Bindlib.mbinder -> unit = fun u v ->
  assert(unset u); u.value := Some(v);
  if !debug_unif then
    let (env,a) = Bindlib.unmbind mkfree v in
    log "unif" "?%i[%a] ← %a" u.key (Array.pp pp_tvar ",") env pp a

(** [occurs u t] checks whether the unification variable [u] occurs in [t]. *)
let rec occurs : unif -> term -> bool = fun r t ->
  match unfold t with
  | Prod{a;b} -> occurs r a || occurs r (Bindlib.subst b Kind)
  | Abst{a;b} -> occurs r a || occurs r (Bindlib.subst b Kind)
  | Appl{a;b} -> occurs r a || occurs r b
  | Unif(u,e) -> u == r || Array.exists (occurs r) e
  | Type      -> false
  | Kind      -> false
  | Vari(_)   -> false
  | Symb(_)   -> false
  | ITag(_)   -> false
  | Wild      -> false

(** [unify u t] tries to unify [u] with [t], and returns a boolean to indicate
    whether it succeeded or not. Note that the function also verifies that the
    body of the unification variable (the binder) is closed. *)
let unify : unif -> term array -> term -> bool = fun u env a ->
  assert(unset u);
  not (occurs u a) &&
  let to_var t = match t with Vari v -> v | _ -> assert false in
  let b = Bindlib.bind_mvar (Array.map to_var env) (lift a) in
  Bindlib.is_closed b && (set_unif u (Bindlib.unbox b); true)

(** [to_prod r e xo] instantiates the unification variable [r] (with [e] as an
    environment) using a product type formed with fresh unification variables.
    The argument [xo] is used to name the bound variable. Note that the binder
    (the body) is constant if [xo] is equal to [None]. *)
let to_prod r e xo =
  let ra = new_unif () in
  let rb = new_unif () in
  let le = Array.map lift e in
  let a = _Unif ra le in
  let fn =
    match xo with
    | None    -> fun _ -> _Unif rb le
    | Some(_) -> fun x -> _Unif rb (Array.append le [|Bindlib.box_of_var x|])
  in
  let x = match xo with Some(x) -> x | None -> "_" in
  let p = Bindlib.unbox (_Prod a x fn) in
  if not (unify r e p) then assert false (* cannot fail *)

(** [eq t u] tests the equality of the two terms [t] and [u]. Note that during
    the comparison, unification variables may be instanciated. *)
let eq : term -> term -> bool = fun a b ->
  let rec eq a b = a == b ||
    let eq_binder = Bindlib.eq_binder mkfree eq in
    match (unfold a, unfold b) with
    | (Vari(x1)       , Vari(x2)              ) -> Bindlib.eq_vars x1 x2
    | (Type           , Type                  ) -> true
    | (Kind           , Kind                  ) -> true
    | (Symb(Sym(s1))  , Symb(Sym(s2))         ) -> s1 == s2
    | (Symb(Def(s1))  , Symb(Def(s2))         ) -> s1 == s2
    | (Appl{a=a1;b=b1}, Appl({a=a2;b=b2} as c)) ->
       (eq a1 a2 && (if a1 != a2 then c.a <- a1; true)) &&
         (eq b1 b2 && (if b1 != b2 then c.b <- b1; true))
    | (Prod{a=a1;b=b1}, Prod({a=a2;b=b2} as c)) ->
       (eq a1 a2 && (if a1 != a2 then c.a <- a1; true)) &&
         (eq_binder b1 b2 && (if b1 != b2 then c.b <- b1; true))
    | (Abst{a=a1;b=b1}, Abst({a=a2;b=b2} as c)) ->
       (eq a1 a2 && (if a1 != a2 then c.a <- a1; true)) &&
         (eq_binder b1 b2 && (if b1 != b2 then c.b <- b1; true))
    | (ITag(i1)       , ITag(i2)              ) -> i1 = i2
    | (Unif(u1,e1)    , Unif(u2,e2)           ) when u1 == u2 -> true
    | (Unif(u,e)      , b                     ) when unify u e b -> true
    | (a              , Unif(u,e)             ) -> unify u e a
    | (_              , _                     ) -> false
  in eq a b

(* NOTE it might be a good idea to undo unification variable instanciations in
   the case where [eq a b] returns [false]. This can be done with "timed refs"
   but for now, this does not seem to be necessary. *)

(** Representation of equality constraints. *)
type constrs = (term * term) list

(** If [constraints] is set to [None] then typechecking is in regular mode. If
    it is set to [Some l] then it is in constraint mode, which means that when
    equality fails a constraint is added to [constrs] instead of the  equality
    function giving up. *)
let constraints = ref None

(* NOTE: constraint mode is only used when type-cheching the left-hand side of
   reduction rules (see function [infer_with_constrs] for mode switching). *)

(** [in_constrs_mode f a] enters constraint mode, runs [f a], exits constraint
    mode and returns the result of the computation with the constraints. *)
let in_constrs_mode : ('a -> 'b) -> 'a -> 'b * constrs = fun f a ->
  constraints := Some([]);
  let res = f a in
  let cs = match !constraints with Some(cs) -> cs | None -> assert false in
  constraints := None; (res, cs)

(** [add_constraint a b] adds an equality constraint between [a] and [b] while
    returning [true], when the program is in constraint mode. When the program
    is in regular mode, the value [false] is immediately returned. *)
let add_constraint : term -> term -> bool = fun a b ->
  match !constraints with
  | None    -> false
  | Some(l) ->
      if !debug_patt then log "cnst" "new constraint [%a == %a]." pp a pp b;
      constraints := Some((a, b)::l); true

(** Representation of a stack for the abstract machine used for evaluation. *)
type stack = term ref list

(* NOTE the stack contain references so that the computation of arguments when
   matching reduction rules may be shared. *)

(** [to_term t stk] builds a term from an abstrack machine state [(t,stk)]. *)
let to_term : term -> stack -> term = fun t args ->
  let rec to_term t args =
    match args with
    | []      -> t
    | u::args -> to_term (appl t !u) args
  in to_term t args

(** [whnf t] returns (almost) a weak head normal form of [t]. When a reduction
    rule is matched, the arguments may need to be normalised.  Their evaluated
    form is kept to avoid useless recomputations. *)
let rec whnf : term -> term = fun t ->
  if !debug_eval then log "eval" "evaluating %a" pp t;
  let (u, stk) = whnf_stk t [] in
  let u = to_term u stk in
  if !debug_eval then log "eval" "produced %a" pp u; u

(** [whnf_stk t stk] performs weak head normalisations of the term [t] applied
    to the argument list (or stack) [stk]. Note that the normalisation is done
    in the sense of [whnf]. *)
and whnf_stk : term -> stack -> term * stack = fun t stk ->
  match (unfold t, stk) with
  (* Push argument to the stack. *)
  | (Appl{a;b} , stk    )         -> whnf_stk a (ref b :: stk)
  (* Beta reduction. *)
  | (Abst{b}   , u::stk )         -> whnf_stk (Bindlib.subst b !u) stk
  (* Try to rewrite. *)
  | (Symb(Def(s)), stk    ) as st ->
      begin
        match find_rule s stk with
        | None        -> st
        | Some(t,stk) -> whnf_stk t stk
      end
  (* In head normal form. *)
  | (_           , _      ) as st -> st

(** [find_rule s stk] attempts to find a reduction rule of [s], that may apply
    under the stack [stk]. If such a rule is found, the machine state produced
    by its application is returned. *)
and find_rule : def -> stack -> (term * stack) option = fun s stk ->
  let stk_len = List.length stk in
  let match_rule r =
    (* First check that we have enough arguments. *)
    if r.arity > stk_len then None else
    (* Substitute the left-hand side of [r] with pattern variables *)
    let env = Array.init (Bindlib.mbinder_arity r.lhs) (fun i -> ITag(i)) in
    let lhs = Bindlib.msubst r.lhs env in
    if !debug_eval then log "eval" "RULE trying rule [%a]" pp_rule (s,r);
    (* Match each argument of the lhs with the terms in the stack. *)
    let rec match_args ps ts =
      match (ps, ts) with
      | ([]   , _    ) -> Some(Bindlib.msubst r.rhs env, ts)
      | (p::ps, t::ts) -> if matching env p t then match_args ps ts else None
      | (_    , _    ) -> assert false (* cannot happen *)
    in
    match_args lhs stk
  in
  List.map_find match_rule s.def_rules

(** [matching ar p t] checks that term [t] matches pattern [p]. The values for
    pattern variables (using the [ITag] node) are stored in [ar], at the index
    they denote. In case several different values are found for a same pattern
    variable, equality modulo is computed to check compatibility. *)
and matching ar p t =
  if !debug_eval then log "matc" "[%a] =~= [%a]" pp p pp !t;
  let res =
    (* First handle patterns that do not need the evaluated term. *)
    match p with
    | ITag(i) when ar.(i) = ITag(i)    -> ar.(i) <- !t; true
    | Wild                             -> true
    | _                                ->
    (* Other cases need the term to be evaluated. *)
    t := whnf !t;
    match (p, !t) with
    | (ITag(i)      , t              ) -> eq_modulo ar.(i) t (* t <> ITag(i) *)
    | (Prod{a;b}    , Prod{a=a2;b=b2}) ->
        let (_,b,b2) = Bindlib.unbind2 mkfree b b2 in
        matching ar a (ref a2) && matching ar b (ref b2)
    | (Abst{b}      , Abst{b=b2}     ) ->
        let (_,b,b2) = Bindlib.unbind2 mkfree b b2 in
        matching ar b (ref b2)
    | (Appl{a;b}    , Appl{a=a2;b=b2}) ->
        matching ar a (ref a2) && matching ar b (ref b2)
    | (Unif(_,_)    , _              ) -> assert false
    | (_            , Unif(_,_)      ) -> assert false
    | (Type         , Type           ) -> true
    | (Kind         , Kind           ) -> true
    | (Vari(x1)     , Vari(x2)       ) -> Bindlib.eq_vars x1 x2
    | (Symb(s1)     , Symb(s2)       ) -> s1 == s2
    | (_            , _              ) -> false
  in
  if !debug_eval then log "matc" (r_or_g res "[%a] =~= [%a]") pp p pp !t; res

(** [eq_modulo ~constr_on a b] tests equality modulo rewriting between [a] and
    [b]. In the case where [constr_on] is true, and constraint mode is enabled
    (see [constraints]), constraints are learnt instead of failing. *)
and eq_modulo : ?constr_on:bool -> term -> term -> bool =
    fun ?(constr_on=false) a b ->
  if !debug_equa then log "equa" "%a == %a" pp a pp b;
  let rec eq_modulo l =
    match l with
    | []                   -> true
    | (a,b)::l when eq a b -> eq_modulo l
    | (a,b)::l             ->
        let (a,sa) = whnf_stk a [] in
        let (b,sb) = whnf_stk b [] in
        let rec sync acc la lb =
          match (la, lb) with
          | ([]   , []   ) -> (a, b, List.rev acc)
          | (a::la, b::lb) -> sync ((!a,!b)::acc) la lb
          | (la   , []   ) -> (to_term a (List.rev la), b, acc)
          | ([]   , lb   ) -> (a, to_term b (List.rev lb), acc)
        in
        let (a,b,l) = sync l (List.rev sa) (List.rev sb) in
        match (unfold a, unfold b) with
        | (a              , b              ) when eq a b -> eq_modulo l
        | (Abst{a=aa;b=ba}, Abst{a=ab;b=bb}) ->
            let x = mkfree (Bindlib.new_var mkfree "_eq_modulo_") in
            eq_modulo ((aa,ab)::(Bindlib.subst ba x, Bindlib.subst bb x)::l)
        | (Prod{a=aa;b=ba}, Prod{a=ab;b=bb}) ->
            let x = mkfree (Bindlib.new_var mkfree "_eq_modulo_") in
            eq_modulo ((aa,ab)::(Bindlib.subst ba x, Bindlib.subst bb x)::l)
        | (a              , b              ) ->
            constr_on && add_constraint a b && eq_modulo l
  in
  let res = eq_modulo [(a,b)] in
  if !debug_equa then log "equa" (r_or_g res "%a == %a") pp a pp b; res
