exports._fixReplicator = function (r) {
    return function (l) {
      return function () {
        console.log('l', l);
        var next = function (x) {
          l._n(x);
        }
        var error = function (e) {
          l._e(e);
        }
        r.next = next;
        r.error = error
        r._n = next
        r._e = error
      }
  }
}

// exports._fixReplicator = function (r) {
//   return function () {
//     r._n = r.next.bind(r)
//     r._e = r.error.bind(r)
//   }
// }
