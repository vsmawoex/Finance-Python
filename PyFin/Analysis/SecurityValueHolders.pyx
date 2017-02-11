# -*- coding: utf-8 -*-
u"""
Created on 2015-8-7

@author: cheng.li
"""

import copy
from collections import defaultdict
from collections import OrderedDict
import sys
import operator
import numpy as np
import pandas as pd
from PyFin.Analysis.SecurityValues cimport SecurityValues
from PyFin.Utilities import to_dict
from PyFin.Math.Accumulators.IAccumulators cimport Accumulator
from PyFin.Math.Accumulators.StatefulAccumulators cimport Shift
from PyFin.Math.Accumulators.IAccumulators cimport Latest
from PyFin.Math.Accumulators.IAccumulators cimport Identity

if sys.version_info > (3, 0, 0):
    div_attr = "truediv"
else:
    div_attr = "div"


cdef class SecurityValueHolder(object):

    cdef public list _dependency
    cdef public SecurityValueHolder _compHolder
    cdef public int _window
    cdef public int _returnSize
    cdef public Accumulator _holderTemplate
    cdef public int updated
    cdef public dict _innerHolders
    cdef public SecurityValues cached

    def __init__(self, dependency='x'):
        if isinstance(dependency, SecurityValueHolder):
            self._dependency = dependency._dependency
            self._compHolder = copy.deepcopy(dependency)
            self._window = self._compHolder._window
        else:
            self._compHolder = None
            if not isinstance(dependency, str) and len(dependency) == 1:
                self._dependency = [dependency[0]]

            elif not isinstance(dependency, str) and len(dependency) >= 1:
                self._dependency = [name for name in dependency]
            else:
                self._dependency = [dependency]
            self._window = 0
        self._returnSize = 1
        self._holderTemplate = None
        self.updated = 0
        self.cached = None
        self._innerHolders = {}

    @property
    def symbolList(self):
        return set(self._innerHolders.keys())

    @property
    def fields(self):
        if isinstance(self._dependency, list):
            return self._dependency
        else:
            return [self._dependency]

    @property
    def valueSize(self):
        return self._returnSize

    @property
    def window(self):
        return self._window

    cpdef push(self, dict data):
        self.updated = 0

        if self._compHolder:
            self._compHolder.push(data)
            data = self._compHolder.value

            for name in data.index():
                try:
                    self._innerHolders[name].push({'x': data[name]})
                except KeyError:
                    self._innerHolders[name] = copy.deepcopy(self._holderTemplate)
                    self._innerHolders[name].push({'x':  data[name]})

        else:
            for name in data:
                try:
                    self._innerHolders[name].push(data[name])
                except KeyError:
                    self._innerHolders[name] = copy.deepcopy(self._holderTemplate)
                    self._innerHolders[name].push(data[name])

    @property
    def value(self):
        if self.updated:
            return SecurityValues(self.cached.values, self.cached.name_mapping)
        else:
            keys = self._innerHolders.keys()
            values = []
            for name in keys:
                try:
                    values.append(self._innerHolders[name].result())
                except ArithmeticError:
                    values.append(np.nan)
            self.cached = SecurityValues(np.array(values), index=OrderedDict(zip(keys, range(len(keys)))))
            self.updated = 1
            return self.cached

    cpdef value_by_names(self, list names):
        if self.updated:
            return self.cached[names]
        else:
            return SecurityValues(np.array([self._innerHolders[name].result() for name in names]),
                                  index=OrderedDict(zip(names, range(len(names)))))

    cpdef value_by_name(self, name):
        if self.updated:
            return self.cached[name]
        else:
            return self._innerHolders[name].result()

    @property
    def holders(self):
        return self._innerHolders

    def isFullByName(self, name):
        return self._innerHolders[name].isFull()

    @property
    def isFull(self):
        for name in self._innerHolders:
            if not self._innerHolders[name].isFull():
                return False
        return True

    def __getitem__(self, filter):
        if isinstance(filter, SecurityValueHolder):
            return FilteredSecurityValueHolder(self, filter)
        else:
            return self.value[filter]

    def __add__(self, right):
        return SecurityAddedValueHolder(self, right)

    def __sub__(self, right):
        return SecuritySubbedValueHolder(self, right)

    def __mul__(self, right):
        return SecurityMultipliedValueHolder(self, right)

    def __div__(self, right):
        return SecurityDividedValueHolder(self, right)

    def __truediv__(self, right):
        return SecurityDividedValueHolder(self, right)

    def __richcmp__(self, right, int op):

        if op == 0:
            return SecurityLtOperatorValueHolder(self, right)
        elif op == 1:
            return SecurityLeOperatorValueHolder(self, right)
        elif op == 2:
            return SecurityEqOperatorValueHolder(self, right)
        elif op == 3:
            return SecurityNeOperatorValueHolder(self, right)
        elif op == 4:
            return SecurityGtOperatorValueHolder(self, right)
        elif op == 5:
            return SecurityGeOperatorValueHolder(self, right)

    def __neg__(self):
        return SecurityNegValueHolder(self)

    def __invert__(self):
        return SecurityInvertValueHolder(self)

    def __and__(self, right):
        return SecurityAndOperatorValueHolder(self, right)

    def __rand__(self, left):
        return SecurityAndOperatorValueHolder(left, self)

    def __or__(self, right):
        return SecurityOrOperatorValueHolder(self, right)

    def __ror__(self, left):
        return SecurityOrOperatorValueHolder(left, self)

    cpdef shift(self, n):
        return SecurityShiftedValueHolder(self, n)

    cpdef transform(self, data, name=None, category_field=None):

        data = data.sort_index()

        for f in self._dependency:
            if f not in data:
                raise ValueError('({0}) dependency is not in input data'.format(f))

        dummy_category = False
        if not category_field:
            category_field = 'dummy'
            data[category_field] = 1
            dummy_category = True
            total_index = list(range(len(data)))
        else:
            total_index = data.index

        if not name:
            name = 'transformed'

        total_category = data[category_field].tolist()
        data = data.select_dtypes([np.number])
        matrix_values = data.as_matrix().astype(np.float64)
        columns = data.columns.tolist()
        split_category, split_values = to_dict(total_index, total_category, matrix_values, columns)

        output_values = np.zeros((len(data), 1))

        start_count = 0
        if not dummy_category:
            for j, dict_data in enumerate(split_values):
                self.push(dict_data)
                end_count = start_count + len(dict_data)
                output_values[start_count:end_count, 0] = self.value_by_names(split_category[j]).values
                start_count = end_count
        else:
            for j, dict_data in enumerate(split_values):
                self.push(dict_data)
                output_values[j, 0] = self.value_by_name(split_category[j][0])

        df = pd.DataFrame(output_values, index=total_category, columns=[name])
        if dummy_category:
            df.index = data.index
        else:
            df[category_field] = df.index
            df.index = data.index

        df.dropna(inplace=True)
        return df


cdef class FilteredSecurityValueHolder(SecurityValueHolder):

    cdef public SecurityValueHolder _filter
    cdef public SecurityValueHolder _computer

    def __init__(self, computer, filtering):
        self._filter = copy.deepcopy(filtering)
        self._computer = copy.deepcopy(computer)
        self._window = max(computer.window, filtering.window)
        self._returnSize = computer.valueSize
        self._dependency = _merge2set(
            self._computer._dependency,
            self._filter._dependency
        )
        self.updated = 0
        self.cached = None

    def isFullByName(self, name):
        return self._computer.isFullByName(name)

    @property
    def isFull(self):
        return self._computer.isFull

    @property
    def symbolList(self):
        return self._computer.symbolList

    @property
    def holders(self):
        return self._computer.holders

    @property
    def value(self):
        if self.updated:
            return self.cached
        else:
            filter_value = self._filter.value.values
            self.cached = self._computer.value.mask(filter_value)
            self.updated = 1
            return self.cached

    cpdef value_by_name(self, name):
        if self.updated:
            return self.cached[name]
        else:
            filter_value = self._filter.value_by_name(name)
            if filter_value:
                return self._computer.value_by_name(name)
            else:
                return np.nan

    cpdef value_by_names(self, names):
        if self.updated:
            return self.cached[names]
        else:
            filter_value = self._filter.value_by_names(names)
            orig_values = self._computer.value_by_names(names)
            return SecurityValues(np.where(filter_value.values, orig_values.values, np.nan), filter_value.name_mapping)

    cpdef push(self, data):
        self._computer.push(data)
        self._filter.push(data)
        self.updated = 0

    def __deepcopy__(self, memo):
        return FilteredSecurityValueHolder(self._computer, self._filter)


cdef class IdentitySecurityValueHolder(SecurityValueHolder):

    cdef public double _value

    def __init__(self, value):
        self._value = value
        self._window = 0
        self._returnSize = 1
        self._dependency = []
        self._innerHolders = {}
        self._holderTemplate = Identity(value)
        self.updated = 0
        self.cached = None

    def isFullByName(self, name):
        return True

    @property
    def isFull(self):
        return True

    cpdef push(self, data):
        for name in data:
            try:
                self._innerHolders[name].push(data)
            except KeyError:
                self._innerHolders[name] = copy.deepcopy(self._holderTemplate)
                self._innerHolders[name].push(data)

        self.updated = 0

    def __deepcopy__(self, memo):
        return IdentitySecurityValueHolder(self._value)


cdef class SecurityUnitoryValueHolder(SecurityValueHolder):

    cdef public SecurityValueHolder _right
    cdef public object _op

    def __init__(self, right, op):
        self._right = copy.deepcopy(right)

        self._window = self._right.window
        self._dependency = copy.deepcopy(self._right._dependency)
        self._returnSize = self._right.valueSize
        self._op = op
        self.updated = 0
        self.cached = None

    def isFullByName(self, name):
        return self._right.isFullByName(name)

    @property
    def isFull(self):
        return self._right.isFull

    @property
    def symbolList(self):
        return self._right.symbolList

    cpdef push(self, data):
        self._right.push(data)
        self.updated = 0

    @property
    def value(self):
        if self.updated:
            return self.cached
        else:
            self.cached = self._op(self._right.value)
            self.updated = 1
            return self.cached

    cpdef value_by_name(self, name):
        if self.updated:
            return self.cached[name]
        else:
            return self._op(self._right.value_by_name(name))

    cpdef value_by_names(self, names):
        if self.updated:
            return self.cached[names]
        else:
            return self._op(self._right.value_by_names(names))

    def __deepcopy__(self, memo):
        return SecurityUnitoryValueHolder(self._right, self._op)


cdef class SecurityNegValueHolder(SecurityUnitoryValueHolder):
    def __init__(self, right):
        super(SecurityNegValueHolder, self).__init__(
            right, operator.neg)

    def __deepcopy__(self, memo):
        return SecurityNegValueHolder(self._right)


cdef class SecurityInvertValueHolder(SecurityUnitoryValueHolder):
    def __init__(self, right):
        super(SecurityInvertValueHolder, self).__init__(
            right, operator.invert)

    def __deepcopy__(self, memo):
        return SecurityInvertValueHolder(self._right)


cdef class SecurityLatestValueHolder(SecurityValueHolder):
    def __init__(self, dependency='x'):
        super(SecurityLatestValueHolder, self).__init__(dependency)
        if self._compHolder:
            self._holderTemplate = Latest(dependency='x')
            self._innerHolders = {
                name: copy.deepcopy(self._holderTemplate) for name in self._compHolder.symbolList
                }
        else:
            self._holderTemplate = Latest(dependency=self._dependency)

    def __deepcopy__(self, memo):
        if self._compHolder:
            return SecurityLatestValueHolder(self._compHolder)
        else:
            return SecurityLatestValueHolder(self._dependency)


cdef class SecurityCombinedValueHolder(SecurityValueHolder):

    cdef public SecurityValueHolder _left
    cdef public SecurityValueHolder _right
    cdef public object _op

    def __init__(self, left, right, op):
        if isinstance(left, SecurityValueHolder):
            self._left = copy.deepcopy(left)
            if isinstance(right, SecurityValueHolder):
                self._right = copy.deepcopy(right)
            elif isinstance(right, str):
                self._right = SecurityLatestValueHolder(right)
            else:
                self._right = IdentitySecurityValueHolder(right)
        elif isinstance(left, str):
            self._left = SecurityLatestValueHolder(left)
            self._right = copy.deepcopy(right)
        else:
            self._left = IdentitySecurityValueHolder(left)
            self._right = copy.deepcopy(right)

        self._window = max(self._left.window, self._right.window)
        self._dependency = _merge2set(
            self._left._dependency, self._right._dependency)
        self._returnSize = self._left.valueSize
        self._op = op
        self.updated = 0
        self.cached = None

    def isFullByName(self, name):
        return self._left.isFullByName(name) and self._right.isFullByName(name)

    @property
    def isFull(self):
        return self._left.isFull and self._right.isFull

    @property
    def symbolList(self):
        return self._left.symbolList.union(self._right.symbolList)

    cpdef push(self, data):
        self._left.push(data)
        self._right.push(data)
        self.updated = 0

    @property
    def value(self):
        if self.updated:
            return self.cached
        else:
            self.cached = self._op(self._left.value, self._right.value)
            self.updated = 1
            return self.cached

    cpdef value_by_name(self, name):
        if self.updated:
            return self.cached[name]
        else:
            return self._op(self._left.value_by_name(name), self._right.value_by_name(name))

    cpdef value_by_names(self, names):
        if self.updated:
            return self.cached[names]
        else:
            return self._op(self._left.value_by_names(names), self._right.value_by_names(names))

    def __deepcopy__(self, memo):
        return SecurityCombinedValueHolder(self._left, self._right, self._op)


cdef class SecurityAddedValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityAddedValueHolder, self).__init__(
            left, right, operator.add)

    def __deepcopy__(self, memo):
        return SecurityAddedValueHolder(self._left, self._right)


cdef class SecuritySubbedValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecuritySubbedValueHolder, self).__init__(
            left, right, operator.sub)

    def __deepcopy__(self, memo):
        return SecuritySubbedValueHolder(self._left, self._right)


cdef class SecurityMultipliedValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityMultipliedValueHolder, self).__init__(
            left, right, operator.mul)

    def __deepcopy__(self, memo):
        return SecurityMultipliedValueHolder(self._left, self._right)


cdef class SecurityDividedValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityDividedValueHolder, self).__init__(
            left, right, getattr(operator, div_attr))

    def __deepcopy__(self, memo):
        return SecurityDividedValueHolder(self._left, self._right)


cdef class SecurityLtOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityLtOperatorValueHolder, self).__init__(
            left, right, operator.lt)

    def __deepcopy__(self, memo):
        return SecurityLtOperatorValueHolder(self._left, self._right)


cdef class SecurityLeOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityLeOperatorValueHolder, self).__init__(
            left, right, operator.le)

    def __deepcopy__(self, memo):
        return SecurityLeOperatorValueHolder(self._left, self._right)


cdef class SecurityGtOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityGtOperatorValueHolder, self).__init__(
            left, right, operator.gt)

    def __deepcopy__(self, memo):
        return SecurityGtOperatorValueHolder(self._left, self._right)


cdef class SecurityGeOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityGeOperatorValueHolder, self).__init__(
            left, right, operator.ge)

    def __deepcopy__(self, memo):
        return SecurityGeOperatorValueHolder(self._left, self._right)


cdef class SecurityEqOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityEqOperatorValueHolder, self).__init__(
            left, right, operator.eq)

    def __deepcopy__(self, memo):
        return SecurityEqOperatorValueHolder(self._left, self._right)


cdef class SecurityNeOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityNeOperatorValueHolder, self).__init__(
            left, right, operator.ne)

    def __deepcopy__(self, memo):
        return SecurityNeOperatorValueHolder(self._left, self._right)


cdef class SecurityAndOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityAndOperatorValueHolder, self).__init__(
            left, right, operator.__and__)

    def __deepcopy__(self, memo):
        return SecurityAndOperatorValueHolder(self._left, self._right)


cdef class SecurityOrOperatorValueHolder(SecurityCombinedValueHolder):
    def __init__(self, left, right):
        super(SecurityOrOperatorValueHolder, self).__init__(
            left, right, operator.__or__)

    def __deepcopy__(self, memo):
        return SecurityOrOperatorValueHolder(self._left, self._right)


cdef class SecurityShiftedValueHolder(SecurityValueHolder):

    def __init__(self, right, n):
        super(SecurityShiftedValueHolder, self).__init__(right)
        self._returnSize = right.valueSize
        self._window = right.window + n
        self._dependency = copy.deepcopy(right._dependency)
        self._holderTemplate = Shift(Latest('x'), n)

        self._innerHolders = {
            name: copy.deepcopy(self._holderTemplate) for name in self._compHolder.symbolList
        }

    def __deepcopy__(self, memo):
        if self._compHolder:
            return SecurityShiftedValueHolder(self._compHolder, self._holderTemplate.lag())
        else:
            return SecurityShiftedValueHolder(self._dependency, self._holderTemplate.lag())


cdef class SecurityIIFValueHolder(SecurityValueHolder):

    cdef public SecurityValueHolder _flag
    cdef public SecurityValueHolder _left
    cdef public SecurityValueHolder _right

    def __init__(self, flag, left, right):

        if not isinstance(flag, SecurityValueHolder):
            if isinstance(flag, str):
                self._flag = SecurityLatestValueHolder(flag)
            else:
                self._flag = IdentitySecurityValueHolder(flag)
        else:
            self._flag = copy.deepcopy(flag)

        if not isinstance(left, SecurityValueHolder):
            if isinstance(left, str):
                self._left = SecurityLatestValueHolder(left)
            else:
                self._left = IdentitySecurityValueHolder(left)
        else:
            self._left = copy.deepcopy(left)

        if not isinstance(right, SecurityValueHolder):
            if isinstance(left, str):
                self._right = SecurityLatestValueHolder(right)
            else:
                self._right = IdentitySecurityValueHolder(right)
        else:
            self._right = copy.deepcopy(right)

        self._window = max(self._flag.window, self._left.window, self._right.window)
        self._dependency = _merge2set(self._flag._dependency, _merge2set(
            self._left._dependency, self._right._dependency))
        self._returnSize = self._flag.valueSize
        self.updated = 0
        self.cached = None

    cpdef isFullByName(self, name):
        return self._flag.isFullByName(name) and self._left.isFullByName(name) and self._right.isFullByName(name)

    @property
    def isFull(self):
        return self._flag.isFull and self._left.isFull and self._right.isFull

    @property
    def symbolList(self):
        return self._flag.symbolList

    cpdef push(self, data):
        self._flag.push(data)
        self._left.push(data)
        self._right.push(data)
        self.updated = 0

    @property
    def value(self):
        if self.updated:
            return self.cached
        else:
            self.cached = SecurityValues(np.where(self._flag.value.values,
                                                  self._left.value.values,
                                                  self._right.value.values),
                                         self._flag.value.name_mapping)
            self.updated = 1
            return self.cached

    cpdef value_by_name(self, name):
        if self.updated:
            return self.cached[name]
        else:
            if self._flag.value_by_name(name):
                return self._left.value_by_name(name)
            else:
                return self._right.value_by_name(name)

    cpdef value_by_names(self, names):
        if self.updated:
            return self.cached[names]
        else:
            flag_value = self._flag.value_by_names(names)
            left_value = self._left.value_by_names(names)
            right_value = self._right.value_by_names(names)
            return SecurityValues(np.where(flag_value.values,
                                           left_value.values,
                                           right_value.values),
                                  flag_value.name_mapping)

    def __deepcopy__(self, memo):
        return SecurityIIFValueHolder(self._flag, self._left, self._right)


def dependencyCalculator(*args):
    res = defaultdict(list)
    tmp = {}
    for value in args:
        tmp = _merge2dict(tmp, value)

    for name in tmp:
        if isinstance(tmp[name], list):
            for field in tmp[name]:
                res[field].append(name)
        else:
            res[tmp[name]].append(name)
    return res


# detail implementation
cdef dict _merge2dict(dict left, dict right):
    res = {}
    for name in left:
        if name in right:
            if isinstance(left[name], list):
                if isinstance(right[name], list):
                    res[name] = list(set(left[name] + right[name]))
                else:
                    res[name] = list(set(left[name] + [right[name]]))
            else:
                if isinstance(right[name], list):
                    res[name] = list(set([left[name]] + right[name]))
                else:
                    res[name] = list(set([left[name]] + [right[name]]))
        else:
            res[name] = left[name]

    for name in right:
        if name not in left:
            res[name] = right[name]
    return res


def _merge2set(left, right):
    if isinstance(left, list):
        if isinstance(right, list):
            res = list(set(left + right))
        else:
            res = list(set(left + [right]))
    else:
        if isinstance(right, list):
            res = list(set([left] + right))
        else:
            res = list(set([left] + [right]))
    return res