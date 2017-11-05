#include "defs.h"

#include <lua.h>

#include <vector>
#include <set>
#include <iostream>


class Minmax
{
private:
    struct value
    {
        double time;
        double value;
    };

    struct less_value
    {
        bool operator()(const value & a, const value & b) const
        { return a.value < b.value; }
    };

    typedef std::multiset<value, less_value>    minmax_collection;
    typedef minmax_collection::iterator         minmax_iterator;
    typedef std::vector<minmax_iterator>        history_collection;

public:
    Minmax(double a_limit) : limit(a_limit) { }

    void add(const double t, const double v);

    double getMin() const;
    double getMax() const;
private:

    double              limit;      // time limit for history
    minmax_collection   minmax;     // elements sorted by value
    history_collection  history;    // elements sorted by time
};

void open_minmax(lua_State* L);
int l_newminmax(lua_State *L);
