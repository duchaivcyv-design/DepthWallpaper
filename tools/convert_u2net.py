"""
Chuyển U²-Net (Apache-2.0, https://github.com/xuebinqin/U-2-Net) từ ONNX sang Core ML
bằng coremltools NeuralNetworkBuilder. Không dùng model của ExiWall.

Đầu vào : u2net_sim.onnx (đã đơn giản hoá bằng onnxsim, input 1x3x320x320)
Đầu ra  : DWSubject.mlmodel (Float16, đầu vào image RGB 320x320, đầu ra 1x1x320x320 xác suất)
"""
import sys
import numpy as np
import onnx
from onnx import numpy_helper, helper, shape_inference
import coremltools as ct
from coremltools.models.neural_network import NeuralNetworkBuilder, quantization_utils
from coremltools.proto import FeatureTypes_pb2 as ft

SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/u2net_sim.onnx"
DST = sys.argv[2] if len(sys.argv) > 2 else "/tmp/DWSubject.mlmodel"
SIZE = 320
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

model = onnx.load(SRC)
inferred = shape_inference.infer_shapes(model)

def shape_of(name, vi_map):
    vi = vi_map.get(name)
    if vi is None:
        return None
    return [d.dim_value for d in vi.type.tensor_type.shape.dim]

vi_map = {v.name: v for v in list(inferred.graph.value_info) + list(inferred.graph.input) + list(inferred.graph.output)}
init = {i.name: numpy_helper.to_array(i) for i in model.graph.initializer}
constants = {}
for n in model.graph.node:
    if n.op_type == "Constant":
        constants[n.output[0]] = numpy_helper.to_array(n.attribute[0].t)

def attr(node, name, default=None):
    for a in node.attribute:
        if a.name == name:
            return helper.get_attribute_value(a)
    return default

input_name = "input.1"
# Đầu vào đặt là MultiArray trước, sau đó đổi thành ảnh bên dưới
from coremltools.models import datatypes
nn = NeuralNetworkBuilder(
    input_features=[(input_name, datatypes.Array(3, SIZE, SIZE))],
    output_features=[("1959", datatypes.Array(1, SIZE, SIZE))],
    disable_rank5_shape_mapping=True,
)

# ----- Tiền xử lý: ảnh (0..255) -> (x/255 - mean)/std -----
spec = nn.spec
pre = spec.neuralNetwork.preprocessing.add()
pre.featureName = input_name
pre.scaler.channelScale = 1.0 / 255.0
pre.scaler.redBias = float(-MEAN[0])
pre.scaler.greenBias = float(-MEAN[1])
pre.scaler.blueBias = float(-MEAN[2])
desc_in = spec.description.input[0]
desc_in.type.imageType.width = SIZE
desc_in.type.imageType.height = SIZE
desc_in.type.imageType.colorSpace = ft.ImageFeatureType.RGB
# Ảnh đầu vào: đổi kiểu feature thành image
desc_in.type.ClearField("multiArrayType")
desc_in.type.imageType.width = SIZE
desc_in.type.imageType.height = SIZE
desc_in.type.imageType.colorSpace = ft.ImageFeatureType.RGB

# Chia cho std theo từng kênh
nn.add_scale(
    name="norm_std",
    W=(1.0 / STD).astype(np.float32),
    b=None,
    has_bias=False,
    input_name=input_name,
    output_name="x_norm",
    shape_scale=[3, 1, 1],
)

tensor_map = {}  # tên ONNX -> tên tensor CoreML
tensor_map[input_name] = "x_norm"

def cur(name):
    return tensor_map.get(name, name)

skipped = []
for node in model.graph.node:
    op = node.op_type
    if op == "Constant":
        continue
    outs = list(node.output)
    ins = list(node.input)
    out = outs[0]
    if op == "Conv":
        W = init[ins[1]]            # (out, in, kh, kw)
        b = init[ins[2]] if len(ins) > 2 and ins[2] in init else None
        pads = attr(node, "pads", [0, 0, 0, 0])
        strides = attr(node, "strides", [1, 1])
        dil = attr(node, "dilations", [1, 1])
        group = attr(node, "group", 1)
        kh, kw = W.shape[2], W.shape[3]
        out_ch, in_ch = W.shape[0], W.shape[1]
        if group != 1:
            raise RuntimeError(f"Conv nhóm chưa hỗ trợ: {node.name}")
        Wc = np.transpose(W, (2, 3, 1, 0)).astype(np.float32)  # (kh, kw, in, out)
        nn.add_convolution(
            name=node.name, kernel_channels=in_ch, output_channels=out_ch,
            height=kh, width=kw, stride_height=strides[0], stride_width=strides[1],
            border_mode="valid", groups=1,
            W=Wc, b=(b.astype(np.float32) if b is not None else None), has_bias=b is not None,
            input_name=cur(ins[0]), output_name=out,
            padding_top=pads[0], padding_bottom=pads[2], padding_left=pads[1], padding_right=pads[3],
            dilation_factors=[dil[0], dil[1]],
        )
    elif op == "Relu":
        nn.add_activation(name=node.name, non_linearity="RELU", input_name=cur(ins[0]), output_name=out)
    elif op == "Sigmoid":
        nn.add_activation(name=node.name, non_linearity="SIGMOID", input_name=cur(ins[0]), output_name=out)
    elif op == "Add":
        nn.add_elementwise(name=node.name, input_names=[cur(ins[0]), cur(ins[1])], output_name=out, mode="ADD")
    elif op == "Concat":
        nn.add_concat_nd(name=node.name, input_names=[cur(i) for i in ins], output_name=out, axis=-3)
    elif op == "MaxPool":
        k = attr(node, "kernel_shape", [2, 2])
        s = attr(node, "strides", [2, 2])
        nn.add_pooling(name=node.name, height=k[0], width=k[1], stride_height=s[0], stride_width=s[1],
                       layer_type="MAX", padding_type="VALID",
                       input_name=cur(ins[0]), output_name=out)
    elif op == "Resize":
        in_shape = shape_of(ins[0], vi_map)
        out_size = constants.get(ins[3]) if ins[3] in constants else init.get(ins[3])
        if in_shape is None or out_size is None:
            raise RuntimeError(f"Không xác định được kích thước Resize: {node.name}")
        sh = in_shape[2] / 1.0
        sw = in_shape[3] / 1.0
        fh = out_size[2] / sh
        fw = out_size[3] / sw
        mode = attr(node, "mode", b"linear")
        if mode != b"linear":
            raise RuntimeError(f"Resize mode {mode} chưa hỗ trợ: {node.name}")
        nn.add_upsample(name=node.name, scaling_factor_h=fh, scaling_factor_w=fw,
                        input_name=cur(ins[0]), output_name=out, mode="BILINEAR",
                        linear_upsample_mode="ALIGN_CORNERS_FALSE")
    else:
        skipped.append(op)
        raise RuntimeError(f"Toán tử chưa hỗ trợ: {op} ({node.name})")

    tensor_map[out] = out

# Đầu ra d0 (xác suất). Đặt đúng tên tensor cuối cùng.
final = [o.name for o in model.graph.output][0]
if cur(final) != "1959":
    nn.add_activation(name="out_identity", non_linearity="LINEAR", input_name=cur(final),
                      output_name="1959", params=[1.0, 0.0])

spec = nn.spec
spec.description.output[0].name = "1959"
ct.utils.save_spec(spec, DST)
print("saved", DST, "layers:", len(spec.neuralNetwork.layers))
