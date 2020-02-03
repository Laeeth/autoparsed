
import autoparsed.autoparsed;
import sumtype;

@Token
enum lparen = "(";

@Token
enum rparen = ")";

@Token
struct Atom {
  string val;
}

class Sexp {
public:
  @Syntax!(lparen, RegexPlus!(OneOf!(Atom, Sexp)), rparen)
  this(SumType!(Atom, Sexp)[] members_){
	members = members_;
  }

  override string toString() {
	import std.array : join;
	import std.algorithm : map;
	return "Sexp( " ~ join(map!(a => a.toString)(members), ", ") ~ ")";
  }
private:
  SumType!(Atom, Sexp)[] members;
}
