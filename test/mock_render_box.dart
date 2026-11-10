import 'package:flutter/material.dart';

class MockRenderBox extends RenderBox {
  @override
  Offset localToGlobal(Offset point, {RenderObject? ancestor}) => Offset.zero;

  @override
  Size get size => Size.zero;
}
