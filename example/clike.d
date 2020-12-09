/// A grammer for a simple C-like language
module clike;

import autoparsed.autoparsed;
import autoparsed.lexer;
import autoparsed.syntax;
import autoparsed.log;

import std.typecons : Tuple;
import std.stdio;
import std.meta;
import std.algorithm;
import std.range;
import std.array;

import sumtype;


@Token{
  enum lcurly = '{';
  enum rcurly = '}';
  enum lparen = '(';
  enum rparen = ')';
  enum comma = ',';
  enum semi = ';';
  enum eq = '=';

  @Syntax!(RegexPlus!(OneOf!(' ', '\t', '\n', '\r')))
    struct Whitespace{
      const(char)[] val;
    }

  @Syntax!(RegexPlus!(OneOf!('-', InRange!('a','z'), InRange!('A', 'Z'))))
    struct Identifier{
      const(char)[] val;
      alias val this;
    }

}

@Syntax!(Identifier)
struct Expression{
  Identifier id;
}

@Syntax!(Identifier, eq, Expression, semi)
struct AssignmentStatement {
  this(Identifier id, Expression exp){
    writeln("assign statment with it: ", id, " and expression ", exp);
  }
}

@Syntax!(Expression, semi)
struct ExpressionStatement {
  Expression exp;
}

alias Statement = OneOf!(AssignmentStatement, ExpressionStatement);

alias ParameterList = AliasSeq!(lparen, RegexStar!(Identifier, Identifier, comma), Optional!(Identifier, Identifier), rparen);

@Syntax!(Identifier, Identifier, ParameterList, lcurly, RegexStar!Statement, rcurly)
struct FunctionDeclaration{

  this(Identifier retType, Identifier name, Tuple!(Identifier, Identifier)[] parameters, Statement.NodeType[] body_){
    writeln("making a function decl with return type ", retType, " named ", name, " with params: ", parameters, " and body: ", body_);
  }

}

@Syntax!(Identifier, Identifier, semi)
struct VariableDeclaration{
  Identifier type, name;
}

alias Declaration = OneOf!(FunctionDeclaration, VariableDeclaration);

@Syntax!(RegexStar!Declaration)
struct CompilationUnit
{
  Declaration.NodeType[] decls;

}


unittest{
  import autoparsed.recursivedescent;

  string program = `type var;
ret func(argA nameA, argB nameB){}
ret gunc(argC nameC){ z = qwerty;}
`;

  auto lexer = Lexer!clike(program);
  auto tokens = lexer.filter!( x => x.match!(
                                 (Whitespace w) => false,
                                 _ => true)
                               ).array;
  writeln("\n\nTOKENS:\n", tokens, "\n\n");

  auto cu = parse!CompilationUnit(tokens);

  writeln("parsed cu is: ", cu);

}
