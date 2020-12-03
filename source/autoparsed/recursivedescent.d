module autoparsed.recursivedescent;
import autoparsed.syntax;
import autoparsed.autoparsed;
import autoparsed.log;

import std.stdio;
import std.conv : to;
import std.typecons;
import std.traits;
import std.meta : AliasSeq, EraseAll;
import std.algorithm;
import std.array;
import std.range.primitives;

import sumtype;

template TypesOnly(T...){
  import std.meta;
  alias TypesOnly = Filter!(isType, T);
}

enum hasUDASafe(alias X, alias UDA) = __traits(compiles, hasUDA!(X, UDA)) && hasUDA!(X, UDA);
enum isArraySafe(X...) = __traits(compiles, isArray!X) && isArray!X;


unittest {

  enum UDA;

  @UDA struct S1{}
  struct S2{}

  static assert(hasUDASafe!(S1, UDA));
  static assert(!hasUDASafe!(S2, UDA));
  static assert(!hasUDASafe!(dchar, UDA));
  
}

struct Payload(T){
  alias Types = T;
  static if(!is(Types == void))
    Types contents;
}

struct ParseError(T){
  alias Types = T;
  T contents;
}

alias DefaultError = ParseError!string;

struct ParseResult(P, PE)
if(is(P : Payload!Args1, Args1...) && is(PE : ParseError!Args2, Args2)){
  SumType!(P, PE) data;
  alias data this;
  alias PayloadType = P;
  this(P p){ data = p;}
  this(PE pe){ data = pe;}
}

bool isParseError(PR: ParseResult!(P, PE), P, PE)(PR pr){
  return pr.data.match!(
    (P p) => false,
    (PE pe) => true);
}

auto getPayload(PR: ParseResult!(P, PE), P, PE)(PR pr){
  return pr.data.match!(
    (P p) => p,
    function P(PE _){assert(false);});
}

auto getParseError(PR: ParseResult!(P, PE), P, PE)(PR pr){
  return pr.data.match!(
    (PE pe) => pe,
    function PE(P _){assert(false);}
  );
}

unittest {
  alias PInt = Payload!int;
  alias PTuple = Payload!(Tuple!(int, string, double));
  alias PEString = ParseError!string;
  ParseResult!(PInt, PEString) p1;
  ParseResult!(PTuple, PEString) p2;
}


template contains(T, Ts...) {
  import std.meta : anySatisfy;
  enum isSame(U) = allSameType!(T, U);
  alias contains = anySatisfy!(isSame, Ts);
}

template partOfStream(T, StreamElement){
  enum partOfStream = is(StreamElement == OneOf!Args.NodeType, Args...) &&
    contains!(T, TemplateArgsOf!(StreamElement.ST));
}

///return a T if it's at the front of the stream
auto parse(T, TokenStream)(ref TokenStream tokenStream)
if(hasUDASafe!(T, Token) &&
   partOfStream!(T, ElementType!TokenStream)){
  
  mixin CTLog!("Parser for already lexed Token `", T, "` from stream of type `", TokenStream, "`");
  RTLog("parsing token `", T.stringof, "` from stream: ", tokenStream);

  alias PayloadType = Payload!T;
  alias ResultType = ParseResult!(PayloadType, DefaultError);
  
  if(tokenStream.empty) return ResultType(DefaultError("empty stream"));
  return tokenStream.front.match!(
    (T t){
      auto ret = ResultType(PayloadType(t));
      tokenStream.popFront;
      return ret;
    },
    _ => ResultType(DefaultError( "looking for "~ T.stringof~ " but found "~ to!string(tokenStream.front)))
  );
  
}

///Parse a token, forwards either to another overload, or the literal checker
auto parse(T, TokenStream)(ref TokenStream tokenStream)
if(isInstanceOf!(TokenType, T)){
  import std.traits: isType;
  mixin CTLog!("Forwarding Parser for TokenType wrapper `", T, "`");

  alias TArgs = TemplateArgsOf!T;
  return parse!TArgs(tokenStream);

}

template SyntaxReturnType(T){
  alias PayloadType = Payload!T;
  alias SyntaxReturnType = ParseResult!(PayloadType, DefaultError);
}

///parse an element that has a constructor annotated with the @Syntax UDA
SyntaxReturnType!T parse(T, TokenStream)(ref TokenStream tokenStream)
if(hasUDASafe!(T, Syntax) && !partOfStream!(T, typeof(tokenStream.front()))) {
  import std.traits : getUDAs, isType, Parameters;
  import std.range: iota;
  import std.meta : Filter, staticMap, aliasSeqOf;

  alias syntax = getUDAs!(T, Syntax)[0];

  mixin CTLog!("Parser for type `", T, "` with annotated constructor syntax`", syntax, "`");
  RTLog("parsing token `", T.stringof, "` with annotated constructor from stream: ", tokenStream);

  alias Seq = TemplateArgsOf!syntax;
  auto parsed =  parse!Seq(tokenStream);

  alias ParsedPayloadType = typeof(parsed).PayloadType;
  
  alias PayloadType = Payload!T;
  alias RetType = ParseResult!(PayloadType, DefaultError);
  
  return parsed.data.match!(
    (typeof(parsed).PayloadType payload) =>
      RetType(PayloadType(construct!T(parsed.getPayload.contents))),
    _ => RetType(DefaultError(to!string(_))));
}

///parse a * expression (0 or more repeats)
auto parse(RS, TokenStream)(ref TokenStream tokenStream)
if(isInstanceOf!(RegexStar, RS)){

  mixin CTLog!("Parser for RegexStar `", RS, "`");
  RTLog("parsing `", RS.stringof, "` from stream: ", tokenStream);

  alias Elems = TemplateArgsOf!RS;
  static if(Elems.length > 1){
    alias ElemType = AliasSeq!(Elems);
  } else {
    alias ElemType = Elems[0];
    static assert(!isInstanceOf!(Optional, ElemType), "RegexStar of an Optional doesn't make sense");
  }
  
  mixin CTLog!("Elem type: `", ElemType, "`");

  
  TokenStream copy = tokenStream;
  auto elem = parse!ElemType(copy);

  alias RetType = typeof(elem).PayloadType.Types; //? always 1 arg here?
  
  RetType[] ret;
  
  while(!elem.isParseError){
    ret ~= elem.getPayload.contents;
    elem = parse!ElemType(copy);
  }

  if(ret.length > 0){
    tokenStream = copy; //something was consumed
  }

  RTLog("regex star returning: `", ret, "` with stream: ", tokenStream);
  alias PayloadType = Payload!(typeof(ret));
  return ParseResult!(PayloadType, DefaultError)(PayloadType(ret));
}

///parse a regex + expression (1 or more repeats)
auto parse(RP, TokenStream)(ref TokenStream tokenStream)
if(isInstanceOf!(RegexPlus, RP)){

  mixin CTLog!("Parser for RegexPlus `", RP, "`");
  RTLog("parsing `", RP.stringof, "` from stream: ", tokenStream);
  
  alias StarType = RegexStar!(TemplateArgsOf!RP);
  auto ret = parse!(StarType)(tokenStream);

  alias PayloadType = typeof(ret).PayloadType;
  alias RetType = ParseResult!(PayloadType, DefaultError);
  
  return ret.getPayload.contents.length > 0 ? RetType(ret.getPayload) :
    RetType(DefaultError("Regex+ didn't find any " ~ RP.stringof));
}

///parse an optional element.  Is always "successful" so, don't check the return value to decide
auto parse(Opt, TokenStream)(ref TokenStream tokenStream)
if(isInstanceOf!(Optional, Opt)){
  mixin CTLog!("Parser for Optional `", Opt, "`");
  RTLog("Parsing `", Opt.stringof, "` from stream: ", tokenStream);
  //defer to the element parse, return whatever they do
  alias Args = TemplateArgsOf!Opt;

  auto res = parse!(Args)(tokenStream);

  alias ResPayloadType = typeof(res).PayloadType;
  alias PayloadType = Payload!(Nullable!(typeof(res).PayloadType.Types));
  alias RetType = ParseResult!(PayloadType, DefaultError); //todo, no error
  
  return res.data.match!(
    (ResPayloadType pt) => RetType(PayloadType(nullable(res.getPayload.contents))),
    _ => RetType(PayloadType())); //successful, but just holds null
  
 }

///parse a choice between alternatives.  Return the first successful option
auto parse(OO, TokenStream)(ref TokenStream tokenStream)
if(isInstanceOf!(OneOf, OO)){
  mixin CTLog!("Parser for OneOf `", OO, "`");
  RTLog("parsing `", OO.stringof, "` from stream: ", tokenStream);

  alias Ts = TemplateArgsOf!(OO.NodeType);
  alias PayloadType = Payload!(OO.NodeType);
  alias RetType = ParseResult!(PayloadType, DefaultError);
  
  static foreach(T; Ts){{
      TokenStream copy = tokenStream; //only advance the stream on success
      auto res = parse!T(copy);
      if(!res.isParseError){
        auto oont = OO.NodeType(res.getPayload.contents);
        tokenStream = copy;
        return RetType(PayloadType(oont));
      }
      
  }}
  return RetType(DefaultError("None of " ~ Ts.stringof ~ " could be parsed"));

}

///Parse a token within an inclusive range of literal values
///TODO: are things other than literals ever useful here?
auto parse(IR, TokenStream)(ref TokenStream tokenStream)
if(isInstanceOf!(InRange, IR)){

  mixin CTLog!("Parser for InRange `", IR, "`");
  RTLog("parsing `", IR.stringof, "` from stream: ", tokenStream);

  enum first = TemplateArgsOf!IR[0];
  enum last = TemplateArgsOf!IR[1];

  static assert(!is(CommonType!(IR.LimitType, ElementType!TokenStream) == void));
                
  
  alias PayloadType = Payload!(CommonType!(IR.LimitType, ElementType!TokenStream));
  alias RetType = ParseResult!(PayloadType, DefaultError);

  if(tokenStream.empty()){
    RTLog("stream empty, returning false");
    return RetType(DefaultError("empty stream"));
  } else if(tokenStream.front >= first && tokenStream.front <= last){
    RTLog("found value in range, returning it");
    auto ret = RetType(PayloadType(tokenStream.front));
    tokenStream.popFront;
    RTLog("stream after parsing literal: ", tokenStream);
    return ret;
  } else {
    RTLog("didn't find it, returning false");
    return RetType(DefaultError("Looking for "~ IR.stringof ~ " but found "~ to!string(tokenStream.front)));
  }
  
}

///returns true if you cannot parse N from the stream right now
///Does not consume any tokens from the stream
auto parse(N, TokenStream)(ref TokenStream tokenStream)
if(isInstanceOf!(Not, N)){

  mixin CTLog!("Parser for Not `", N, "`");
  RTLog("parsing Not element, `", N.stringof, "`, from stream: ", tokenStream);

  alias ElemType = TemplateArgsOf!N;
  static assert(!isInstanceOf!(Optional, ElemType), "Not of Optional doesn't make sense");

  TokenStream copy = tokenStream; //don't consume any input
  auto ret = parse!(ElemType)(copy);
  alias PayloadType = Payload!void;
  alias RetType = ParseResult!(PayloadType, DefaultError);
  if(!ret.isParseError){
    return RetType(DefaultError("Not failed, could parse " ~ typeof(ret).stringof));
  } else {
    
    RTLog("returning from Not element, `", N.stringof, "`, from stream: ", tokenStream, " with ", ret);
    return RetType(PayloadType());
  }

}

///returns the next token, whatever it is
auto parse(T, TokenStream)(ref TokenStream tokenStream)
if(is(ElementType!TokenStream : T) || is (T : Token)){
  
  mixin CTLog!("Parser for wildcard token");
  RTLog("parsing wildcard token from stream: ", tokenStream);

  alias U = typeof(tokenStream.front());
  alias PayloadType = Payload!U;
  alias RetType = ParseResult!(PayloadType, DefaultError);
  
  if(tokenStream.empty){ return RetType(DefaultError("empty stream")); }
  
  auto ret = tokenStream.front;
  tokenStream.popFront;
  return RetType(PayloadType(ret));
}

///parse a sequence of tokens in orders
template parse(Ts...){
auto parse(TokenStream)(ref TokenStream tokenStream)
  if(Ts.length > 1){ //isInstanceOf!(Sequence, S)){

  mixin CTLog!("Parser for Sequence `", Ts, "`");
  RTLog("parsing `", Ts.stringof, "` from stream: ", tokenStream);
  
  import std.typecons : Tuple;
  import std.meta : ReplaceAll, Filter;
  
  //alias Ts = S.Elements;
  alias TType = ElementType!TokenStream;
  alias TokensReplaced = ReplaceTokensRecursive!(TType, Ts);
  alias Values = ValueTypes!(TokenStream, TokensReplaced);

  alias RetType = Tuple!Values;

  RetType ret;
  alias PayloadType = Payload!RetType;
  alias ResultType = ParseResult!(PayloadType, DefaultError);
  
  static size_t argNumber(size_t syntaxNumber)(){
    size_t v = 0;
    static foreach(i; 0..syntaxNumber){
      static if(!isInstanceOf!(Not, Ts[i])){ 
        ++v;
      }
    }
    return v;
  }

  void set(size_t i, T)(T val){
    mixin CTLog!("setting ", i, " of type " , typeof(ret[i]), " with ", T, " for Ts: ", Ts);
    RTLog("setting arg number ", i, " from ", val);
    ret[i] = convert!(typeof(ret[i]))(val);
    RTLog("the converted value is ", ret[i]);
  }

  TokenStream copy = tokenStream; //don't advance on failure
  static foreach(i, elem; Ts){{
      auto piece = .parse!elem(copy);
      RTLog("parsed piece: ", piece, " element number ", i);
      if(piece.isParseError){
        static if(is(elem == Token)){ enum elemName = "Token"; }
        else enum elemName = elem.stringof;
        return ResultType(DefaultError("Couldn't parse " ~ elemName));
      }
      alias piecePayloadTypes = typeof(piece).PayloadType.Types;
      //does piece actually hold some data?
      static if(!isInstanceOf!(Not, elem)){
        set!(argNumber!i)(piece.getPayload.contents);
      }
    }}
    tokenStream = copy;
  return ResultType(PayloadType(ret));

}
}

template hasValue(alias T){
  enum hasValue = isType!T && !isInstanceOf!(Not, T);
}

template ValueTypes(TokenStream, Ts...){

  import std.meta : staticMap, Filter;

  alias TsWithValues = Filter!(hasValue, Ts);

  enum notNot(alias X) = !isInstanceOf!(Not, X);
  alias ValuesWithoutNots = Filter!(notNot, Ts);
  alias ValTypeWrapper(alias X) = ValueType!(TokenStream, X);
  alias ValueTypes = staticMap!(ValTypeWrapper, ValuesWithoutNots);
  mixin CTLog!("ValueTypes of ", Ts, " are ", ValueTypes);
}

template ValueType(TokenStream, alias T){
  static if(isInstanceOf!(OneOf, T)){
    alias ValueType = T.NodeType;
  } else static if(isInstanceOf!(InRange, T)){
    alias ValueType = T.LimitType;
  } else static if(isInstanceOf!(RegexStar, T) || isInstanceOf!(RegexPlus, T)){
    alias ChildType = ReturnType!(
      (TokenStream ts) => parse!(TemplateArgsOf!T)(ts) ).PayloadType.Types;
    alias ValueType = SliceOf!ChildType;
  } else static if(isInstanceOf!(Optional, T)){
    alias ChildType = ReturnType!(
      (TokenStream ts) => parse!(TemplateArgsOf!T)(ts)).PayloadType.Types;
    alias ValueType = Nullable!ChildType;
  } else static if(!isType!T){
    //type for literals
    alias ValueType = TokenType!T;
  } else {
    alias ValueType = T;
  }
  mixin CTLog!("val type for ", T, " is ", ValueType);
}


///Is a literal at the front?
auto parse(alias Lit, TokenStream)(ref TokenStream tokenStream){

  alias StreamElementType = ElementType!TokenStream;
  alias PayloadType = Payload!(TokenType!Lit);
  alias RetType = ParseResult!(PayloadType, DefaultError);

  mixin CTLog!("Parse(non-check) literal `", Lit, "`",
    "payload type: `", PayloadType, "` RetType: `", RetType, "`");
  RTLog("parsing(non-check) for `", Lit.stringof, "` with type ",
    typeof(Lit).stringof," from stream: ", tokenStream);


  if(tokenStream.empty()){
    RTLog("stream empty, returning false");
    return RetType(DefaultError("empty stream"));
  } else {
    //stream is one of many possible token types
    static if(is(StreamElementType == OneOf!(Args).NodeType, Args...)){
      auto fn = tokenStream.front;

      auto ret = tokenStream.front.data.match!(
        function RetType(TokenType!Lit tl){ return RetType(PayloadType(TokenType!Lit()));},
        _ => RetType(DefaultError("did't find " ~ Lit ~ " token"))
      );
      if(!ret.isParseError)
        tokenStream.popFront;
      return ret;
      
    } else { //stream is probably a dchar[]
      if(tokenStream.front == Lit){
        RTLog("found it, returning true");
        auto ret = RetType(PayloadType());
        tokenStream.popFront;
        RTLog("stream after parsing literal: ", tokenStream);
        return ret;
      } else {
        RTLog("didn't find it, returning false");
        return RetType(DefaultError("Looking for "~ Lit~ " but found "~ to!string(tokenStream.front)));
      }
    }
  }
}

template CArgs(T){
  pragma(msg, "getting CArgs of ", T);
  static assert(isType!T);
  static if(!isAggregateType!T){
    alias CArgs = Tuple!(Unqual!T);
  } else static if(isTuple!T){
    alias CArgs = Tuple!(staticMap!(Unqual, T.Types));
  } else static if(hasMember!(T, "__ctor")){
    alias CArgs = Tuple!(staticMap!(Unqual, Parameters!(__traits(getMember, T, "__ctor"))));
  } else {
    alias CArgs = Tuple!(staticMap!(Unqual, Fields!T));
  }
}

enum MultiArgConstructor(T) = isAggregateType!T || isTuple!T;

template CommonValueType(T) if(is(T : OneOf!Args.NodeType, Args...)){
  import std.meta : allSatisfy;

  template isValueToken(T){
    static if(isInstanceOf!(TokenType,T)){
      enum isValueToken = !isType!(TemplateArgsOf!T[0]);
    } else {
      enum isValueToken = false;
    }
  }

  enum allValueTokens = allSatisfy!(isValueToken, TemplateArgsOf!T);
  static if(allValueTokens){

    alias getValue(T)= TemplateArgsOf!T[0];
    alias TokenValues = staticMap!(getValue, TemplateArgsOf!T);
    alias getType(alias V) = typeof(V);
    alias ValueTypes = staticMap!(getType, TokenValues);

    alias CT = CommonType!(ValueTypes);
    static if(is(CT == void)){
      enum HasCommonType = false;
    } else {
      enum HasCommonType = true;
      alias CommonValueType = CT;
    }

  } else {
    enum HasCommonType = false;
  }

  static if(!HasCommonType){
    alias CommonValueType = void;
  }
}




Target convert(Target, Src)(Src src){
  import std.conv : to;
  import std.traits : isNarrowString;
  import std.utf : byCodeUnit;
  import std.typecons : isTuple;
  
  mixin CTLog!("convert, src ", Src, " Target: ", Target);
  RTLog("Converting ", src, " to type ", Target.stringof);
  static if(is(Src : Target)){
    return src;
  } else static if(is(Src: OneOf!Args.NodeType, Args...)){

    //can a common type work for all the variants?
    alias CVT = CommonValueType!Src;
    static assert(!is(CVT == void), "Can't pass a " ~ Src.stringof ~
                  " as expected constructor argument type " ~ Target.stringof);

    CVT val = src.match!(x => x.value);
    return to!Target(val);

  } else static if(isArray!Target && isArray!Src){
    import std.algorithm: map;
    import std.array;
    RTLog("doing array conversion... Converting ", src, " of type ", Src.stringof, " to ", Target.stringof);
    static if(isNarrowString!Src){
      //fun with autodecoding!
      return map!(convert!(ForeachType!Target, ForeachType!Src))(src.byCodeUnit).array;
    } else {
      return map!(convert!(ForeachType!Target, ForeachType!Src))(src).array;
    }
  } else static if(isInstanceOf!(Nullable, Src)){
    RTLog("Type is nullable");
    Target ret = [];
    pragma(msg, "convert dealing with a nullable, about to convert a ", typeof(src.get()), " to a ", ElementType!Target);
    if(!src.isNull()) ret = to!Target([convert!(ElementType!Target)(src.get)]);
    RTLog("conversion result is: `", ret, "`");
    return ret;
  } else static if(isInstanceOf!(TokenType, Src)){
    return convert!Target(src.value);
  } else static if(isTuple!Src){
    return construct!Target(src);
  } else {
    return to!(Target)(src);
  }
}



//src is the constructor arg.  Target is the syntax element
template Matches(Src, Target){
  import std.meta : anySatisfy;
  import std.algorithm : canFind;
  mixin CTLog!("Match check: ", Src, " ", Target);
  static if(is(Src == OneOf!OOArgs.NodeType, OOArgs...)){
    enum MatchOne(alias X) = isType!X && .Matches!(X, Target);
    pragma(msg, "any satisfy case");
    enum Matches = anySatisfy!(MatchOne, OOArgs);
    pragma(msg, "any satisfy case for ", Src, " and ", Target, " is ", Matches);
  } else static if(is(Target == OneOf!OOArgs.NodeType, OOArgs...)){
    
    enum MatchOne(alias X) = isType!X && .Matches!(Src, X);
    enum DirectMatch = anySatisfy!(MatchOne, OOArgs);
    
    static if(DirectMatch){
      enum Matches = true;
    } else {
      alias CVT = CommonValueType!Target;
      enum Matches = is(CVT == void) ? false : is(CVT: Src);
    }
  } else static if(isInstanceOf!(Nullable, Target)){
    //BUG!!! What about truly optional parameters?
    enum Matches = .Matches!(Src, SliceOf!(TemplateArgsOf!Target));
  } else static if(isInstanceOf!(TokenType, Target)){
    enum Matches =  is(Target.type : Src);
  } else static if(isTuple!Target){
    static if(Target.length == 1 ){
      enum Matches = .Matches!(Src, Target.Types[0]);
    } else static if(isTuple!Src){
      enum AR = ArgRanges!(Wrap!(Src.Types), Wrap!(Target.Types), 0);
      enum Matches = AR.length == Target.Types.length && !AR.canFind(-1);

    } else {
      //can we call ArgRanges successfully?
      enum AR = ArgRanges!(Wrap!(Src), Wrap!(Target.Types), 0);
      enum Matches = AR.length == Target.Types.length && !AR.canFind(-1);
    }
  } else static if(isArray!Src){
    enum Matches = isArray!Target && Matches!(ElementType!Src, ElementType!Target);
  } else {
    enum Matches = is(Target: Src);
  }
  
  mixin CTLog!(Src, "matches ", Target, "?: ",  Matches);
}

private struct Wrap(T...){}


enum size_t SkipArg = -2; //this syntax element shouldn't get passed to a constructor
//probably a literal token

template ArgRanges(CA, TA, size_t Ci){

  /*
    Cargs empty? 
      Targs empty or skippable?  OK, we're done
      Otherwise: error

    Current Carg an array?
      Targ is an array, match it
      Targ matches base type of the array, append it
      Targ doesn't match, move to next Carg

    Current Carg is a scalar?
      targ matches?  good, advance
      targ skippable?  advance targ
      otherwise error

    Current Carg is a tuple?
    
   */

  alias Cargs = TemplateArgsOf!CA;
  alias Targs = TemplateArgsOf!TA;

  mixin CTLog!("computing arg ranges with Cargs: ", Cargs, " and Targs ", Targs);
  
  static if(Cargs.length == 0){
    static if(Targs.length == 0){
      enum size_t[] ArgRanges = []; //all done
    } else static if(isInstanceOf!(TokenType, Targs[0])){
      //Token types have no value, skip them
      enum size_t[] ArgRanges = [SkipArg] ~ .ArgRanges!(CA, Wrap!(Targs[1..$]), Ci);
    } else {
      enum size_t[] ArgRanges = [-1]; //unmatched Synax params
    }
    
  } else static if(Targs.length == 0){
    
    static if(isArray!(Cargs[0])){
      //done with this array element, move on, and hopefully this is the last carg
      //todo verify that at least 1 Targs is assigned to each Carg array element
      enum size_t[] ArgRanges = .ArgRanges!(Wrap!(Cargs[1..$]), TA, Ci +1);
    } else {
      enum size_t[] ArgRanges = [-1];
    }
    
  } else static if(isArray!(Cargs[0])){

    static if(isArray!(Targs[0])){
      static if(Matches!(ElementType!(Cargs[0]), ElementType!(Targs[0]))){
        enum size_t[] ArgRanges = [Ci] ~ //Ti matches Ci, continue
          .ArgRanges!(Wrap!(Cargs), Wrap!(Targs[1..$]), Ci);
      } else {
        //Different element types, could be OK if the Targ matched this array
        enum size_t[] ArgRanges = .ArgRanges!(CA, Wrap!(Targs[1..$]), Ci);
      }
      
    } else {
      alias base = ElementType!(Cargs[0]);
      static if(isInstanceOf!(TokenType, Targs[0])){
        //Targ is unused, move on
        enum size_t[] ArgRanges = [SkipArg] ~ .ArgRanges!(CA, Wrap!(Targs[1..$]), Ci);
      } else static if(isInstanceOf!(Nullable, Targs[0])){
        //Nullables match either nullables or array, try to match it to an array
        enum matches = Matches!(base, TemplateArgsOf!(Targs[0]));
        static if(matches){
          //cool
          enum size_t[] ArgRanges = [Ci] ~ .ArgRanges!(CA, Wrap!(Targs[1..$]), Ci);
        } else {
          //move along
          enum size_t[] ArgRanges = .ArgRanges!(Wrap!(Cargs[1..$]), TA, Ci + 1);
        }
        
      } else static if(Matches!(base, Targs[0])){
        //Ti can be part of the array at Ci
        pragma(msg, "checking array base type match for ", Cargs, " and ", Targs);
        enum size_t[] ArgRanges = [Ci] ~ .ArgRanges!(CA, Wrap!(Targs[1..$]), Ci);
      } else static if(isTuple!(Targs[0])){
        pragma(msg, "checking array tuple match for ", Cargs, " and ", Targs);
        enum tupleMatches = Matches!(Cargs[0], Targs[0]);
        static if(tupleMatches){
          //move along
          enum size_t[] ArgRanges = [Ci] ~ .ArgRanges!(CA, Wrap!(Targs[1..$]), Ci);
        } else {
          enum size_t[] ArgRanges = .ArgRanges!(Wrap!(Cargs[1..$]), TA, Ci +1);
        }
      } else {
        //No more Tis match this array, move on
        enum size_t[] ArgRanges = .ArgRanges!(Wrap!(Cargs[1..$]), TA, Ci +1);
      }
    }
    
  } else {
    static if(isInstanceOf!(TokenType, Targs[0])){
      //Targ is unused, move on
      enum size_t[] ArgRanges = [SkipArg] ~ .ArgRanges!(CA, Wrap!(Targs[1..$]), Ci);
    } else static if(Matches!(Cargs[0], Targs[0])){
      //Ti will be passed for Ci
      enum size_t[] ArgRanges = [Ci] ~
        .ArgRanges!(Wrap!(Cargs[1..$]), Wrap!(Targs[1..$]), Ci + 1);
    } else  {
      //no match
      enum size_t[] ArgRanges = [-1];
    }
  }
}

template directlyAssignable(T, Args...){
  pragma(msg, "directly assignable? ", T, " from ", Args);
  static if(Args.length != 1){
    enum directlyAssignable = false;
  } else static if( is(Args[0] : T)){
    enum directlyAssignable = true;
  } else static if(isTuple!(Args[0])){
    import std.algorithm : canFind;
    enum AR = ArgRanges!(Wrap!T, Wrap!(Args[0].Types), 0);

    bool argsCheck()(){
      static foreach(i, ar; AR){
        static if(ar < Args[0].length){
          pragma(msg, "arg check: ", i, " ", ar, " ", Args[0].Types[i], " ", is(Args[0].Types[i] : T));
        }
        static if(ar == -1)
          return false;
        else static if(ar != SkipArg && !is(Args[0].Types[i] : T))
          return false;
      }
      return true;
    }
    pragma(msg, "AR before argsCheck: ", AR);
    enum directlyAssignable = argsCheck!()();
    
  } else {
    enum directlyAssignable = false;
  }
}


auto simplifyPayload(T)(T t){
  pragma(msg, "Simpligying T: ", T);
  static if(isTuple!T && !isInstanceOf!(Nullable, T)){
    
    alias SimplifiedType(X) = ReturnType!( () => simplifyPayload(X.init));
    alias SimplifiedTypes = staticMap!(SimplifiedType, T.Types);
    pragma(msg, "simplified types for ", T.Types, " are ", SimplifiedTypes);
    
    alias FilteredTypes = EraseAll!(void, SimplifiedTypes);
    pragma(msg, "filtered types are ", FilteredTypes);
    
    FilteredTypes ret;
    
    static if(FilteredTypes.length == 0){
      return; //void
    } else {
      
      auto filteredIndexOf(size_t i)(){
        size_t ret  = 0;
        static foreach(ind; 0.. i){
          static if(!is(SimplifiedTypes[ind] == void))
            ret++;
        }
        return ret;
      }
      
      static foreach(i; 0..T.Types.length){
        static if(!is(SimplifiedTypes[i] == void)){
          ret[filteredIndexOf!i] = simplifyPayload(t[i]);
        }
      }

      static if(FilteredTypes.length == 1){
        return ret[0];
      } else {
        return tuple(ret);
      }
    }
    
  } else static if(isArray!T){
    return t.map!simplifyPayload.array;
  } else static if(is(T: OneOf!Args.NodeType, Args...)){
    //can a common type work for all the variants?
    alias CVT = CommonValueType!T;
    static if(is(CVT == void)){
      return t;
    } else {
      return CVT(t.match!(x => x.value));
    }

  } else static if(isInstanceOf!(TokenType, T)){
    return; //void
  } else {
    return t;
  }
}




/* Construct calls that from JSON that make sense...


tuple("calling construct to make a ", (Whitespace), " from ", (NodeType[]))
tuple("calling construct to make a ", (QuotedString), " from ", (Tuple!(TokenType!('"'), Tuple!dchar[], TokenType!('"'))))
IFFY: tuple("calling construct to make a ", (const(dchar)[]), " from ", (Tuple!(TokenType!('"'), Tuple!dchar[], TokenType!('"'))))
IFFY: tuple("calling construct to make a ", (const(dchar)), " from ", (dchar))

tuple("calling construct to make a ", (Number), " from ", (Tuple!(Nullable!(TokenType!('-')), dchar[], Nullable!(TokenType!('.')), dchar[])))
iffy tuple("calling construct to make a ", (string), " from ", (Tuple!(Nullable!(TokenType!('-')), dchar[], Nullable!(TokenType!('.')), dchar[])))


tuple("calling construct to make a ", (JSONArray), " from ", (Tuple!(TokenType!('['), Tuple!(NodeType, TokenType!(','))[], Nullable!(NodeType), TokenType!(']'))))
tuple("calling construct to make a ", (NodeType[]), " from ", (Tuple!(TokenType!('['), Tuple!(NodeType, TokenType!(','))[], Nullable!(NodeType), TokenType!(']'))))
IFFY tuple("calling construct to make a ", (NodeType[]), " from ", (TokenType!('[')), (Tuple!(NodeType, TokenType!(','))[]), (Nullable!(NodeType)), (TokenType!(']')))

tuple("calling construct to make a ", (NodeType), " from ", (Tuple!(NodeType, TokenType!(','))))
IFFY: tuple("calling construct to make a ", (NodeType), " from ", (NodeType), (TokenType!(',')))

 */


auto make(T, Args...)(Args args){
  static if(is(T == class)){
    return new T(args);
  } else {
    return T(args);
  }
}

T construct(T, Args)(Args args){

  pragma(msg, "\n\n");
  mixin CTLog!("calling construct to make a ", T, " from ", Args);
  RTLog("calling construct to make a ", T.stringof, " from ", args);

  auto simplified = simplifyPayload(args);
  alias Stype = typeof(simplified);

  pragma(msg, "simplified type of ", Args, " is ", Stype);

  
  static if(is(Stype : T)){
    pragma(msg, "simplified version implicitly converts, cool");
    return make!T(simplified);
  } else {
    pragma(msg,  "simplified version doesn't implicitly convert, need to do some work");

    alias Cargs = CArgs!T;
    pragma(msg, "Cargs: ", Cargs);

    static if(!isTuple!Stype){
      //one arg simplified type, better be a 1 arg constructor
      static assert(Cargs.length == 1, "One arg simplified type");
      return make!T(convert!(Cargs.Types[0])(simplified));
    } else {
    

      enum AR = ArgRanges!(Cargs, Stype, 0);
      pragma(msg, "Cargs: ", Cargs, " Stype: ", Stype, " AR: ", AR);
      
      Cargs cargs;
      
      static foreach(i, ar; AR){
        pragma(msg, "i: ", i, " ar: ", ar);
        static if(isArray!(Cargs[ar])){
          cargs[ar] ~= convert!(Cargs.Types[ar])(simplified[i]);
        } else {
          cargs[ar] = convert!(Cargs.Types[ar])(simplified[i]);
        }
      }
      
      return make!T(cargs.expand);
    }
  }

}

template ReplaceTokenRecursive(Replacement, alias T)
if(!isType!T){
  alias ReplaceTokenRecursive = T;
 }

template ReplaceTokenRecursive(Replacement, T){
  static if(isType!T){
    static if(is(TemplateArgsOf!T)){
      alias Ts = TemplateArgsOf!T;
      alias Temp = TemplateOf!T;
      alias ReplaceTokenRecursive = Temp!(ReplaceTokensRecursive!(Replacement, Ts));
    } else {
      static if(is(T == Token)){
        alias ReplaceTokenRecursive = Replacement;
      } else {
        alias ReplaceTokenRecursive = T;
      }
    }
  } else {
    alias ReplaceTokenRecursive = T;
  }
}

template ReplaceTokensRecursive(Replacement, Ts...){
  import std.meta : staticMap;
  alias F(alias T) = ReplaceTokenRecursive!(Replacement, T);
  alias ReplaceTokensRecursive = staticMap!(F, Ts);

}

unittest {
    //  static assert(is(ReplaceTokensRecursive!(dchar, '"', (RegexStar!(Not!'"', Token)), '"', "`") ==
    //                   RegexStar!(Not!'"', dchar)));
}


template SliceOf(T){
  alias SliceOf = T[];
}
