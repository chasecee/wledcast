import json
from pathlib import Path

import cv2
import numpy as np

from wledcast.wled.pixel_writer import PixelWriter


def _ddp_fixture() -> dict:
    writer = PixelWriter("127.0.0.1")
    payload = bytes(range(0, 255)) * 6
    packets = []
    data_offset = 0
    for i in range(0, len(payload), writer.DDP_MAX_DATALEN):
        packet_data = payload[i : i + writer.DDP_MAX_DATALEN]
        is_last_packet = i + writer.DDP_MAX_DATALEN >= len(payload)
        packet = writer._create_ddp_packet(packet_data, data_offset, is_last_packet)
        packets.append(packet.hex())
        data_offset += len(packet_data)
    return {
        "input_length": len(payload),
        "max_data_len": writer.DDP_MAX_DATALEN,
        "destination_id": writer.DDP_DESTINATION_ID,
        "sequence_id": writer.sequence_id,
        "packets": packets,
    }


def _filter_fixture() -> dict:
    frame = np.array(
        [
            [[255, 0, 0], [0, 255, 0], [0, 0, 255], [125, 125, 125]],
            [[255, 255, 0], [0, 255, 255], [255, 0, 255], [10, 20, 30]],
            [[50, 100, 150], [220, 160, 40], [140, 80, 220], [200, 200, 200]],
            [[0, 0, 0], [255, 255, 255], [18, 28, 38], [88, 108, 128]],
        ],
        dtype=np.uint8,
    )
    filters = {
        "sharpen": 0.1,
        "saturation": 1.0,
        "brightness": 0.3,
        "contrast": 1.0,
        "balance_r": 1.0,
        "balance_g": 0.7,
        "balance_b": 0.45,
    }
    output = cv2.resize(frame, (4, 4), interpolation=cv2.INTER_AREA)
    hsv = cv2.cvtColor(output, cv2.COLOR_RGB2HSV)
    h, s, v = cv2.split(hsv)
    gray = cv2.cvtColor(output, cv2.COLOR_RGB2GRAY)
    s_enhanced = cv2.addWeighted(s, filters["saturation"], gray, 1 - filters["saturation"], 0)
    output = cv2.cvtColor(cv2.merge([h, s_enhanced, v]), cv2.COLOR_HSV2RGB)
    black = np.zeros_like(output)
    output = cv2.addWeighted(output, filters["brightness"], black, 1 - filters["brightness"], 0)
    mean_luminance = np.mean(output)
    gray_img = np.full_like(output, mean_luminance)
    output = cv2.addWeighted(output, filters["contrast"], gray_img, 1 - filters["contrast"], 0)
    kernel = np.array([[0, -1, 0], [-1, 4, -1], [0, -1, 0]]) * filters["sharpen"]
    kernel[1, 1] += 1
    output = cv2.filter2D(output, -1, kernel)
    scale = np.array([filters["balance_r"], filters["balance_g"], filters["balance_b"]])[np.newaxis, np.newaxis, :]
    output = (output * scale).astype(np.uint8)
    return {
        "input_width": 4,
        "input_height": 4,
        "output_width": 4,
        "output_height": 4,
        "filters": filters,
        "input_pixels": frame.flatten().tolist(),
        "output_pixels": output.flatten().tolist(),
    }


def _wled_state_fixtures() -> dict:
    return {
        "matrix_2d": {
            "input": {
                "seg": [{"on": False, "start": 0, "stop": 10}, {"on": True, "start": 0, "stop": 64, "startY": 0, "stopY": 32}]
            },
            "expected": {"width": 64, "height": 32},
        },
        "matrix_1d": {
            "input": {"seg": [{"on": True, "start": 0, "stop": 150}]},
            "expected": {"width": 150, "height": 1},
        },
    }


def main():
    root = Path(__file__).resolve().parents[1]
    out = root / "Tests" / "WledCoreTests" / "Fixtures"
    out.mkdir(parents=True, exist_ok=True)
    (out / "ddp_fixture.json").write_text(json.dumps(_ddp_fixture(), indent=2))
    (out / "filter_fixture.json").write_text(json.dumps(_filter_fixture(), indent=2))
    (out / "wled_state_fixtures.json").write_text(json.dumps(_wled_state_fixtures(), indent=2))


if __name__ == "__main__":
    main()
